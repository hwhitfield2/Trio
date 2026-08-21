// Trio Web Viewer — page logic.
//
// Screens: pair (scan or paste the host's pairing code, confirm the
// verification code) → connect (subscribe for pushes, show the registration
// code for the host to scan, wait for the first snapshot) → dashboard.
//
// The page makes no network requests of its own: data arrives exclusively as
// encrypted pushes from the host, decrypted here and in the service worker.
/* global TrioCrypto, TrioStore, TrioFormat, TrioChart, qrcode, jsQR */
(function () {
  'use strict';

  const STALE_AFTER_SECONDS = 15 * 60;

  const screens = {
    pair: document.getElementById('screen-pair'),
    verify: document.getElementById('screen-verify'),
    connect: document.getElementById('screen-connect'),
    dashboard: document.getElementById('screen-dashboard')
  };

  let pendingBundle = null;
  let scanStream = null;
  let scanRafId = 0;
  let staleTicker = 0;

  function show(name) {
    stopScan();
    for (const [key, section] of Object.entries(screens)) {
      section.hidden = key !== name;
    }
  }

  function setText(id, text) {
    document.getElementById(id).textContent = text;
  }

  // ---------------------------------------------------------------- pairing

  function parsePairingBundle(text) {
    let bundle;
    try {
      bundle = JSON.parse(text.trim());
    } catch (error) {
      return null;
    }
    if (!bundle || bundle.type !== 'trio-viewer-pairing' || bundle.v !== 1) return null;
    if (!bundle.secret || !bundle.follower_id || !bundle.vapid_public_key) return null;
    return bundle;
  }

  async function handlePairingInput(text) {
    const bundle = parsePairingBundle(text);
    if (!bundle) {
      if (text.trim().startsWith('{') && text.includes('trio-follower-pairing')) {
        setText('pair-error', 'That is a follower-app pairing code. In Trio, use “Pair Web Viewer” to create a code for this page.');
      } else if (text.trim().length > 0) {
        setText('pair-error', 'That code is not a Trio web viewer pairing code.');
      }
      return;
    }
    pendingBundle = bundle;
    setText('verify-host', bundle.host_name || 'Trio');
    setText('verify-name', bundle.follower_name || 'Web Viewer');
    setText('verify-code', await TrioCrypto.verificationCode(bundle.secret));
    show('verify');
  }

  async function confirmPairing() {
    const bundle = pendingBundle;
    if (!bundle) return;
    await TrioStore.set('pairing', {
      followerId: bundle.follower_id,
      followerName: bundle.follower_name || 'Web Viewer',
      hostName: bundle.host_name || 'Trio',
      secret: bundle.secret,
      units: bundle.units || 'mg/dL',
      vapidPublicKey: bundle.vapid_public_key,
      pairedAt: Date.now()
    });
    pendingBundle = null;
    // A fresh pairing must not inherit a subscription bound to an older
    // pairing's VAPID key.
    await startConnect(true);
  }

  // ---------------------------------------------------------------- camera

  async function startScan(onCode) {
    const video = document.getElementById('scan-video');
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d', { willReadFrequently: true });
    try {
      scanStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment' },
        audio: false
      });
    } catch (error) {
      setText('pair-error', 'Camera access was refused. Paste the pairing code instead.');
      return;
    }
    video.srcObject = scanStream;
    video.hidden = false;
    await video.play();

    const tick = () => {
      if (!scanStream) return;
      if (video.readyState >= video.HAVE_CURRENT_DATA) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        context.drawImage(video, 0, 0);
        const image = context.getImageData(0, 0, canvas.width, canvas.height);
        const code = jsQR(image.data, image.width, image.height, { inversionAttempts: 'dontInvert' });
        if (code && code.data) {
          stopScan();
          onCode(code.data);
          return;
        }
      }
      scanRafId = requestAnimationFrame(tick);
    };
    scanRafId = requestAnimationFrame(tick);
  }

  function stopScan() {
    cancelAnimationFrame(scanRafId);
    if (scanStream) {
      for (const track of scanStream.getTracks()) track.stop();
      scanStream = null;
    }
    const video = document.getElementById('scan-video');
    video.hidden = true;
    video.srcObject = null;
  }

  // ---------------------------------------------------------------- connect

  function isiOSBrowserTab() {
    const iOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
      || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    return iOS && !window.navigator.standalone;
  }

  function subscriptionMatchesKey(subscription, vapidPublicKey) {
    const key = subscription.options && subscription.options.applicationServerKey;
    if (!key) return false;
    const current = new Uint8Array(key);
    const expected = TrioCrypto.base64urlToBytes(vapidPublicKey);
    return current.length === expected.length && current.every((byte, i) => byte === expected[i]);
  }

  async function startConnect(forceNewSubscription) {
    show('connect');
    setText('connect-status', '');
    document.getElementById('btn-connect-retry').hidden = true;
    document.getElementById('connect-qr').innerHTML = '';
    const pairing = await TrioStore.get('pairing');
    if (!pairing) {
      show('pair');
      return;
    }

    if (!('serviceWorker' in navigator) || !('PushManager' in window)) {
      setText(
        'connect-status',
        isiOSBrowserTab()
          ? 'On iPhone and iPad, add this page to the Home Screen first (Share → Add to Home Screen), then open it from there — Safari only allows push for installed web apps.'
          : 'This browser does not support web push. Use a current Chrome, Edge, Firefox or Safari.'
      );
      return;
    }

    try {
      const registration = await navigator.serviceWorker.register('./sw.js');
      await navigator.serviceWorker.ready;

      // Safari only grants the permission prompt inside a user gesture; a
      // connect that runs on page load gets an automatic denial. The retry
      // button re-runs this under a fresh tap.
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        setText(
          'connect-status',
          permission === 'denied' && Notification.permission === 'denied'
            ? 'Notifications are blocked for this site. Allow them in the browser settings, then tap the button below.'
            : 'The viewer needs notification permission to receive data pushes. Tap the button below to ask again.'
        );
        document.getElementById('btn-connect-retry').hidden = false;
        return;
      }

      // Keep a live subscription that already belongs to this pairing —
      // "Show Registration Code" must display the address the host knows,
      // not silently mint a new one and strand the old. Only a fresh
      // pairing (different VAPID key) starts clean.
      let subscription = await registration.pushManager.getSubscription();
      if (subscription && (forceNewSubscription || !subscriptionMatchesKey(subscription, pairing.vapidPublicKey))) {
        await subscription.unsubscribe();
        subscription = null;
      }
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: TrioCrypto.base64urlToBytes(pairing.vapidPublicKey)
        });
      }

      await showRegistrationCode(pairing, subscription);
    } catch (error) {
      setText('connect-status', `Could not subscribe for pushes: ${error.message || error}`);
      document.getElementById('btn-connect-retry').hidden = false;
    }
  }

  async function showRegistrationCode(pairing, subscription) {
    const json = subscription.toJSON();
    const proof = await TrioCrypto.registrationProof(
      pairing.secret,
      pairing.followerId,
      json.endpoint,
      json.keys.p256dh,
      json.keys.auth
    );
    const payload = JSON.stringify({
      v: 1,
      type: 'trio-viewer-push',
      follower_id: pairing.followerId,
      endpoint: json.endpoint,
      p256dh: json.keys.p256dh,
      auth: json.keys.auth,
      proof
    });

    const qr = qrcode(0, 'L');
    qr.addData(payload, 'Byte');
    qr.make();
    const holder = document.getElementById('connect-qr');
    holder.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 4, scalable: true });
    setText('connect-status', 'In Trio, tap “Scan Browser Code” and point the camera here. Data appears moments after the scan.');
    await TrioStore.remove('needsReregistration');
  }

  // ---------------------------------------------------------------- dashboard

  async function renderDashboard() {
    const pairing = await TrioStore.get('pairing');
    if (!pairing) {
      show('pair');
      return;
    }
    const stored = await TrioStore.get('snapshot');
    if (!stored || !stored.data) return; // stay on connect until data arrives

    show('dashboard');
    const snapshot = stored.data;
    const units = snapshot.units || pairing.units || 'mg/dL';
    const now = Date.now() / 1000;
    const reading = (snapshot.readings || [])[0];

    const currentEl = document.getElementById('current-bg');
    if (reading) {
      currentEl.textContent = TrioFormat.displayGlucose(reading.sgv, units);
      currentEl.className = `current-bg ${TrioChart.stateClass(reading.sgv, snapshot.ranges)}`;
      setText('current-arrow', TrioFormat.arrow(reading.direction));
      setText('current-age', `${TrioFormat.timeAgoText(reading.date, now)} · ${units}`);
    } else {
      currentEl.textContent = '--';
      setText('current-arrow', '');
      setText('current-age', 'No readings yet');
    }

    setText('pill-iob', typeof snapshot.iob === 'number' ? `${snapshot.iob.toFixed(2)} U` : '–');
    setText('pill-cob', typeof snapshot.cob === 'number' ? `${Math.round(snapshot.cob)} g` : '–');
    setText(
      'pill-eventual',
      typeof snapshot.eventual_bg === 'number'
        ? `${TrioFormat.displayGlucose(snapshot.eventual_bg, units)} ${units}`
        : '–'
    );
    setText(
      'pill-loop',
      typeof snapshot.last_loop === 'number' ? TrioFormat.timeAgoText(snapshot.last_loop, now) : '–'
    );

    const banner = document.getElementById('status-banner');
    if (snapshot.suspended) {
      banner.hidden = false;
      banner.className = 'banner banner-critical';
      const who = snapshot.suspended_by ? ` by ${snapshot.suspended_by}` : '';
      banner.textContent = `Insulin delivery is suspended${who}${snapshot.suspend_acknowledged ? ' (acknowledged on the host)' : ''}.`;
    } else if (snapshot.temp_target) {
      banner.hidden = false;
      banner.className = 'banner banner-info';
      banner.textContent = `Temp target “${snapshot.temp_target.name}”: ${TrioFormat.displayGlucose(snapshot.temp_target.target, units)} ${units} for ${Math.round(snapshot.temp_target.duration)} min.`;
    } else if (snapshot.override) {
      banner.hidden = false;
      banner.className = 'banner banner-info';
      banner.textContent = `Override “${snapshot.override.name}” is active.`;
    } else {
      banner.hidden = true;
    }

    const stale = document.getElementById('stale-banner');
    const age = now - (snapshot.timestamp || 0);
    if (age > STALE_AFTER_SECONDS) {
      stale.hidden = false;
      stale.textContent = `No new data for ${Math.round(age / 60)} minutes. The last known state is shown.`;
      document.getElementById('dashboard-content').classList.add('is-stale');
    } else {
      stale.hidden = true;
      document.getElementById('dashboard-content').classList.remove('is-stale');
    }

    const reregister = document.getElementById('reregister-banner');
    reregister.hidden = !(await TrioStore.get('needsReregistration'));

    setText('footer-connection', `Connected to ${pairing.hostName} as “${pairing.followerName}” · read-only`);

    TrioChart.render(document.getElementById('chart'), snapshot, { now });

    const prefs = (await TrioStore.get('prefs')) || {};
    document.getElementById('pref-notifications').checked = prefs.statusNotifications !== false;
  }

  // ---------------------------------------------------------------- wiring

  async function unpair() {
    const registration = await ('serviceWorker' in navigator
      ? navigator.serviceWorker.getRegistration()
      : Promise.resolve(null));
    if (registration) {
      const subscription = await registration.pushManager.getSubscription();
      if (subscription) await subscription.unsubscribe();
      // Unpairing means this device should stop showing the data — including
      // the glucose readout sitting in the notification shade.
      const notifications = await registration.getNotifications().catch(() => []);
      for (const notification of notifications) notification.close();
    }
    await TrioStore.clearAll();
    document.getElementById('settings').open = false;
    show('pair');
  }

  async function reregister() {
    const pairing = await TrioStore.get('pairing');
    if (!pairing) return;
    await startConnect();
  }

  function wire() {
    document.getElementById('btn-scan').addEventListener('click', () => {
      setText('pair-error', '');
      startScan((code) => handlePairingInput(code));
    });
    document.getElementById('btn-paste').addEventListener('click', () => {
      setText('pair-error', '');
      handlePairingInput(document.getElementById('paste-input').value);
    });
    document.getElementById('btn-verify-confirm').addEventListener('click', confirmPairing);
    document.getElementById('btn-verify-cancel').addEventListener('click', () => {
      pendingBundle = null;
      show('pair');
    });
    document.getElementById('btn-unpair').addEventListener('click', () => {
      if (window.confirm('Forget this pairing? Also revoke this viewer in Trio’s Remote Control settings.')) {
        unpair();
      }
    });
    document.getElementById('btn-reregister').addEventListener('click', reregister);
    document.getElementById('btn-show-code').addEventListener('click', reregister);
    document.getElementById('btn-connect-retry').addEventListener('click', () => startConnect());
    document.getElementById('btn-connect-startover').addEventListener('click', () => {
      if (window.confirm('Forget this pairing and start over?')) unpair();
    });
    document.getElementById('pref-notifications').addEventListener('change', async (event) => {
      const prefs = (await TrioStore.get('prefs')) || {};
      prefs.statusNotifications = event.target.checked;
      await TrioStore.set('prefs', prefs);
    });

    if ('serviceWorker' in navigator) {
      navigator.serviceWorker.addEventListener('message', (event) => {
        if (!event.data) return;
        if (event.data.type === 'snapshot') {
          TrioStore.remove('needsReregistration').then(renderDashboard);
        } else if (event.data.type === 'needsReregistration') {
          renderDashboard();
        }
      });
    }

    // Staleness and "minutes ago" change with no push arriving.
    staleTicker = window.setInterval(() => {
      if (!screens.dashboard.hidden) renderDashboard();
    }, 30000);
    void staleTicker;

    window.addEventListener('resize', () => {
      if (!screens.dashboard.hidden) renderDashboard();
    });
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) restore();
    });
  }

  async function restore() {
    // Mid-verification there is nothing stored yet; yanking the user off the
    // code screen because the tab lost focus for a moment helps nobody.
    if (pendingBundle && !screens.verify.hidden) return;
    const pairing = await TrioStore.get('pairing');
    if (!pairing) {
      show('pair');
      return;
    }
    const stored = await TrioStore.get('snapshot');
    if (stored && stored.data) {
      await renderDashboard();
    } else {
      await startConnect();
    }
  }

  wire();
  restore();
})();
