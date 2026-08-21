// Trio Web Viewer — the glucose chart.
//
// One axis (glucose); insulin and carbs are drawn as labeled markers against
// the readings, never as a second scale. Readings are colored by the *host's*
// display ranges from the snapshot, so a reading is the same color here as on
// the host's own screen. Identity never rides on color alone: state is also
// vertical position, and treatments differ by shape (triangle = bolus,
// circle = carb) and carry direct labels.
(function (root) {
  'use strict';

  const SVG_NS = 'http://www.w3.org/2000/svg';
  const MMOL_FACTOR = 0.0555;

  function el(name, attributes) {
    const node = document.createElementNS(SVG_NS, name);
    for (const [key, value] of Object.entries(attributes || {})) {
      node.setAttribute(key, value);
    }
    return node;
  }

  function displayGlucose(mgdl, units) {
    if (units === 'mmol/L') return (mgdl * MMOL_FACTOR).toFixed(1);
    return String(Math.round(mgdl));
  }

  function stateClass(sgv, ranges) {
    const low = ranges && ranges.low ? ranges.low : 70;
    const high = ranges && ranges.high ? ranges.high : 180;
    if (sgv < low) return 'bg-low';
    if (sgv > high) return 'bg-high';
    return 'bg-in-range';
  }

  function timeLabel(seconds) {
    return new Date(seconds * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }

  // Nice y-axis ticks for the glucose domain, in mg/dL.
  function yTicks(yMin, yMax, units) {
    const step = units === 'mmol/L' ? 54 : 50; // 3 mmol/L or 50 mg/dL
    const ticks = [];
    for (let value = Math.ceil(yMin / step) * step; value <= yMax; value += step) {
      if (value > 0) ticks.push(value);
    }
    return ticks;
  }

  function render(container, snapshot, options) {
    const opts = options || {};
    const now = opts.now || Date.now() / 1000;
    const width = Math.max(280, container.clientWidth || 320);
    const height = 260;
    const margin = { top: 14, right: 44, bottom: 26, left: 8 };
    const plotW = width - margin.left - margin.right;
    const plotH = height - margin.top - margin.bottom;

    container.textContent = '';
    const readings = (snapshot.readings || []).slice().reverse(); // oldest first
    if (readings.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'chart-empty';
      empty.textContent = 'No readings yet.';
      container.appendChild(empty);
      return;
    }

    const units = snapshot.units || 'mg/dL';
    const ranges = snapshot.ranges || null;
    const lowLine = ranges && ranges.low ? ranges.low : (snapshot.low || 70);
    const highLine = ranges && ranges.high ? ranges.high : (snapshot.high || 180);

    const tMin = readings[0].date;
    const tMax = Math.max(now, readings[readings.length - 1].date);
    const sgvValues = readings.map((r) => r.sgv);
    const yMin = Math.min(40, Math.min(...sgvValues) - 10);
    const yMax = Math.max(Math.max(...sgvValues) + 25, highLine + 40);

    const x = (t) => margin.left + ((t - tMin) / Math.max(1, tMax - tMin)) * plotW;
    const y = (v) => margin.top + plotH - ((v - yMin) / Math.max(1, yMax - yMin)) * plotH;

    const svg = el('svg', {
      viewBox: `0 0 ${width} ${height}`,
      width: '100%',
      height,
      role: 'img',
      'aria-label': `Glucose over the last ${Math.round((tMax - tMin) / 3600)} hours`
    });

    // Recessive grid + axis labels on the right, out of the data's way.
    for (const tick of yTicks(yMin, yMax, units)) {
      svg.appendChild(el('line', {
        x1: margin.left, x2: margin.left + plotW, y1: y(tick), y2: y(tick), class: 'grid-line'
      }));
      const label = el('text', { x: width - margin.right + 6, y: y(tick) + 3, class: 'axis-label' });
      label.textContent = displayGlucose(tick, units);
      svg.appendChild(label);
    }

    // The host's display thresholds, as quiet dashed guides.
    for (const guide of [lowLine, highLine]) {
      svg.appendChild(el('line', {
        x1: margin.left, x2: margin.left + plotW, y1: y(guide), y2: y(guide), class: 'threshold-line'
      }));
      const label = el('text', { x: width - margin.right + 6, y: y(guide) + 3, class: 'axis-label threshold-label' });
      label.textContent = displayGlucose(guide, units);
      svg.appendChild(label);
    }

    // Hour ticks along the bottom.
    const firstHour = Math.ceil(tMin / 3600) * 3600;
    for (let t = firstHour; t <= tMax; t += 3600) {
      const label = el('text', { x: x(t), y: height - 8, class: 'axis-label axis-label-x' });
      label.textContent = timeLabel(t);
      svg.appendChild(label);
    }

    // Carbs and boluses, each against the reading nearest in time.
    const nearestY = (t) => {
      let best = readings[0];
      for (const reading of readings) {
        if (Math.abs(reading.date - t) < Math.abs(best.date - t)) best = reading;
      }
      return y(best.sgv);
    };

    for (const carb of snapshot.carbs || []) {
      if (carb.t < tMin || carb.t > tMax) continue;
      const cx = x(carb.t);
      const cy = Math.min(nearestY(carb.t) + 18, margin.top + plotH - 4);
      svg.appendChild(el('circle', { cx, cy, r: 5, class: 'mark-carb' }));
      const label = el('text', { x: cx, y: cy + 16, class: 'mark-label' });
      label.textContent = `${carb.g} g`;
      svg.appendChild(label);
    }

    for (const bolus of snapshot.boluses || []) {
      if (bolus.t < tMin || bolus.t > tMax) continue;
      const cx = x(bolus.t);
      const cy = Math.max(nearestY(bolus.t) - 14, margin.top + 4);
      const size = bolus.s ? 4 : 5.5;
      svg.appendChild(el('path', {
        d: `M ${cx} ${cy + size} L ${cx - size} ${cy - size} L ${cx + size} ${cy - size} Z`,
        class: bolus.s ? 'mark-bolus mark-bolus-smb' : 'mark-bolus'
      }));
      // SMBs are frequent and tiny; labeling every one is noise. A bolus a
      // person asked for gets its number.
      if (!bolus.s) {
        const label = el('text', { x: cx, y: cy - size - 4, class: 'mark-label' });
        label.textContent = `${bolus.a} U`;
        svg.appendChild(label);
      }
    }

    // Readings last, on top.
    for (const reading of readings) {
      svg.appendChild(el('circle', {
        cx: x(reading.date), cy: y(reading.sgv), r: 3.2, class: `mark-reading ${stateClass(reading.sgv, ranges)}`
      }));
    }

    // Hover: nearest reading gets a crosshair and a tooltip.
    const crosshair = el('line', { y1: margin.top, y2: margin.top + plotH, class: 'crosshair', visibility: 'hidden' });
    svg.appendChild(crosshair);
    const tooltip = document.createElement('div');
    tooltip.className = 'chart-tooltip';
    tooltip.hidden = true;

    function onPointer(event) {
      const rect = svg.getBoundingClientRect();
      // Screen x → viewBox x → time, inverting the same map the marks were
      // drawn with (the plot does not span the full SVG width).
      const viewX = ((event.clientX - rect.left) / rect.width) * width;
      const fraction = Math.min(Math.max((viewX - margin.left) / plotW, 0), 1);
      const t = tMin + fraction * (tMax - tMin);
      let best = readings[0];
      for (const reading of readings) {
        if (Math.abs(reading.date - t) < Math.abs(best.date - t)) best = reading;
      }
      const cx = x(best.date);
      crosshair.setAttribute('x1', cx);
      crosshair.setAttribute('x2', cx);
      crosshair.setAttribute('visibility', 'visible');
      tooltip.hidden = false;
      tooltip.textContent = `${displayGlucose(best.sgv, units)} ${units} · ${timeLabel(best.date)}`;
      const left = Math.min(Math.max((cx / width) * rect.width - 50, 4), rect.width - 120);
      tooltip.style.left = `${left}px`;
    }

    function onLeave() {
      crosshair.setAttribute('visibility', 'hidden');
      tooltip.hidden = true;
    }

    svg.addEventListener('pointermove', onPointer);
    svg.addEventListener('pointerdown', onPointer);
    svg.addEventListener('pointerleave', onLeave);

    container.appendChild(svg);
    container.appendChild(tooltip);
  }

  root.TrioChart = { render, displayGlucose, stateClass };
})(typeof self !== 'undefined' ? self : globalThis);
