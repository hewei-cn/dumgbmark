#!/usr/bin/env node
//
// Regenerates the camera reference vectors asserted by vsbm-selfcheck.
//
// These are the exact expressions from cznull's renderer
// (Hotment/volumeshader-simulator/js/Raymarcher.js, draw()):
//
//   origin  = (len*cos(ang1)*cos(ang2) + cenx,
//              len*sin(ang2)          + ceny,
//              len*sin(ang1)*cos(ang2) + cenz)
//   right   = (sin(ang1), 0, -cos(ang1))
//   up      = (-sin(ang2)*cos(ang1), cos(ang2), -sin(ang2)*sin(ang1))
//   forward = (-cos(ang1)*cos(ang2), -sin(ang2), -sin(ang1)*cos(ang2))
//
// Usage: node Tools/reference/dump_js_camera.js

const CASES = [
  { ang1: 2.8,  ang2: 0.4, len: 1.6 },
  { ang1: 2.81, ang2: 0.4, len: 1.6 },
  { ang1: 2.8,  ang2: 0.4, len: 2.6 },
];

const f = (x) => x.toFixed(9);

for (const { ang1, ang2, len } of CASES) {
  const c1 = Math.cos(ang1), s1 = Math.sin(ang1);
  const c2 = Math.cos(ang2), s2 = Math.sin(ang2);

  const origin  = [len * c1 * c2, len * s2, len * s1 * c2];
  const right   = [s1, 0.0, -c1];
  const up      = [-s2 * c1, c2, -s2 * s1];
  const forward = [-c1 * c2, -s2, -s1 * c2];

  console.log(`ang1=${ang1} ang2=${ang2} len=${len}`);
  console.log(`  origin  = (${origin.map(f).join(', ')})`);
  console.log(`  right   = (${right.map(f).join(', ')})`);
  console.log(`  up      = (${up.map(f).join(', ')})`);
  console.log(`  forward = (${forward.map(f).join(', ')})`);
  console.log('');
}

// Reference march geometry, for the record.
console.log(`step*len at len=1.6        = ${0.002 * 1.6}`);
console.log(`max march distance (k=1001) = ${0.002 * 1.6 * 1001}`);
console.log(`hit cutoff 2*len            = ${2.0 * 1.6}`);
console.log(`aspect terms at 1024x1024   = x ${1024 * 2 / 2048}, y ${1024 * 2 / 2048}`);
