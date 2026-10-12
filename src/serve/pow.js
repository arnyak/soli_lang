// Soli proof of work: solves the challenge of every `<input data-soli-pow>`
// (rendered by pow_field() / form_with(..., {"pow": true})).
//
// The work starts as soon as the page shows, so it is usually done before the
// visitor has finished typing; a submit before then waits for it, then goes
// on. The answer is `<challenge>:<nonce>` such that SHA-256 of it starts with
// the number of zero bits the challenge names — what spam_check(req) verifies.
//
// Instant navigation swaps the body without reloading this script: init()
// runs on load and on every `soli:load`, and is idempotent per input.
(function () {
  "use strict";

  // SHA-256 (FIPS 180-4), synchronous. crypto.subtle answers each hash in a
  // promise, far too slow for the ~100 000 hashes a challenge takes.
  var K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]);
  var W = new Uint32Array(64);
  var H = new Uint32Array(8);

  function rotr(x, n) {
    return (x >>> n) | (x << (32 - n));
  }

  // Hash `length` bytes of `bytes` (a buffer with room for the padding) and
  // return the first 32-bit word of the digest, plus the second in H[1]:
  // enough to count up to 64 leading zero bits.
  function sha256(bytes, length) {
    var bitLength = length * 8;
    var padded = ((length + 9 + 63) >> 6) << 6;
    bytes[length] = 0x80;
    for (var p = length + 1; p < padded - 8; p++) bytes[p] = 0;
    for (var q = 0; q < 8; q++) bytes[padded - 1 - q] = q < 4 ? (bitLength >>> (8 * q)) & 0xff : 0;

    H[0] = 0x6a09e667; H[1] = 0xbb67ae85; H[2] = 0x3c6ef372; H[3] = 0xa54ff53a;
    H[4] = 0x510e527f; H[5] = 0x9b05688c; H[6] = 0x1f83d9ab; H[7] = 0x5be0cd19;
    for (var offset = 0; offset < padded; offset += 64) {
      for (var i = 0; i < 16; i++) {
        var j = offset + i * 4;
        W[i] = (bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3];
      }
      for (var t = 16; t < 64; t++) {
        var s0 = rotr(W[t - 15], 7) ^ rotr(W[t - 15], 18) ^ (W[t - 15] >>> 3);
        var s1 = rotr(W[t - 2], 17) ^ rotr(W[t - 2], 19) ^ (W[t - 2] >>> 10);
        W[t] = (W[t - 16] + s0 + W[t - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (var r = 0; r < 64; r++) {
        var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var ch = (e & f) ^ (~e & g);
        var t1 = (h + S1 + ch + K[r] + W[r]) | 0;
        var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0;
        d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] += a; H[1] += b; H[2] += c; H[3] += d;
      H[4] += e; H[5] += f; H[6] += g; H[7] += h;
    }
    return H;
  }

  function leadingZeroBits(digest) {
    var first = digest[0] >>> 0;
    if (first !== 0) return Math.clz32(first);
    return 32 + Math.clz32(digest[1] >>> 0);
  }

  function solve(input) {
    if (input.__soliPow) return input.__soliPow;
    var challenge = input.getAttribute("data-soli-pow") || "";
    var bits = parseInt(challenge.split(".")[1], 10);
    var prefix = new TextEncoder().encode(challenge + ":");
    // Room for the prefix, a 16-digit nonce and the SHA-256 padding.
    var buffer = new Uint8Array(prefix.length + 16 + 72);
    buffer.set(prefix);
    input.__soliPow = new Promise(function (resolve) {
      if (!(bits > 0)) return resolve();
      var nonce = 0;
      function chunk() {
        var deadline = Date.now() + 40;
        while (Date.now() < deadline) {
          for (var n = 0; n < 2000; n++, nonce++) {
            var digits = String(nonce);
            for (var k = 0; k < digits.length; k++) buffer[prefix.length + k] = digits.charCodeAt(k);
            if (leadingZeroBits(sha256(buffer, prefix.length + digits.length)) >= bits) {
              input.value = challenge + ":" + digits;
              return resolve();
            }
          }
        }
        // Yield to the page between slices: typing stays fluid.
        setTimeout(chunk, 0);
      }
      chunk();
    });
    return input.__soliPow;
  }

  function init() {
    var inputs = document.querySelectorAll("input[data-soli-pow]");
    for (var i = 0; i < inputs.length; i++) {
      if (!inputs[i].value) solve(inputs[i]);
    }
  }

  // Capture, so this runs before instant navigation's own submit handler: a
  // form whose work is not done yet is held, then submitted again once it is.
  document.addEventListener(
    "submit",
    function (event) {
      var form = event.target;
      var input = form && form.querySelector && form.querySelector("input[data-soli-pow]");
      if (!input || input.value) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      var submitter = event.submitter && event.submitter.form === form ? event.submitter : undefined;
      solve(input).then(function () {
        if (form.requestSubmit) form.requestSubmit(submitter);
        else form.submit();
      });
    },
    true
  );

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
  document.addEventListener("soli:load", init);
})();
