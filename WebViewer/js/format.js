// Trio Web Viewer — formatting shared by the page and the service worker.
(function (root) {
  'use strict';

  const MMOL_FACTOR = 0.0555;

  // Nightscout-style trend names, as the host's snapshot carries them.
  const ARROWS = {
    DoubleUp: '↑↑',
    SingleUp: '↑',
    FortyFiveUp: '↗',
    Flat: '→',
    FortyFiveDown: '↘',
    SingleDown: '↓',
    DoubleDown: '↓↓'
  };

  root.TrioFormat = {
    displayGlucose(mgdl, units) {
      if (units === 'mmol/L') return (mgdl * MMOL_FACTOR).toFixed(1);
      return String(Math.round(mgdl));
    },

    arrow(direction) {
      return ARROWS[direction] || '';
    },

    minutesAgo(seconds, now) {
      const reference = now || Date.now() / 1000;
      return Math.max(0, Math.round((reference - seconds) / 60));
    },

    timeAgoText(seconds, now) {
      const minutes = root.TrioFormat.minutesAgo(seconds, now);
      if (minutes < 1) return 'just now';
      if (minutes === 1) return '1 minute ago';
      if (minutes < 60) return `${minutes} minutes ago`;
      const hours = Math.floor(minutes / 60);
      return hours === 1 ? '1 hour ago' : `${hours} hours ago`;
    }
  };
})(typeof self !== 'undefined' ? self : globalThis);
