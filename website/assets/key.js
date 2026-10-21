/* fitz's stuff :: key core
   the exact same arithmetic runs inside the hub, so any change here has to be
   mirrored in FitzHub.lua or every key stops working. */
(function () {
  "use strict";

  var U32 = 4294967296;
  var HEX_LIMIT = 16777216;

  // split so the seed is not one greppable string in the bundle
  var SEED = ["fitz", "-2f8c", "1a7d5e"].join("");

  function mul32(a, b) {
    var lo = (a % 65536) * b;
    var hi = Math.floor(a / 65536) * b;
    return (lo + (hi % 65536) * 65536) % U32;
  }

  function hash32(text, seed) {
    var h = (seed === undefined ? 2166136261 : seed) % U32;
    for (var i = 0; i < text.length; i++) {
      h = mul32(h, 16777619);
      h = (h + text.charCodeAt(i)) % U32;
      h = mul32(h, 2246822519);
    }
    return h;
  }

  function hex6(value) {
    return (Math.floor(value) % HEX_LIMIT).toString(16).toUpperCase().padStart(6, "0");
  }

  function normalizeDevice(raw) {
    if (typeof raw !== "string") return null;
    var clean = raw.replace(/\s+/g, "").toUpperCase();
    return /^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/.test(clean) ? clean : null;
  }

  function bucketNow() {
    return Math.floor(Date.now() / 1000 / 3600);
  }

  function keyFor(device, bucket) {
    var material = SEED + "|" + device + "|" + bucket;
    var a = hash32(material);
    var b = hash32(material + "|b", a);
    return "FITZ-" + hex6(bucket) + "-" + hex6(a) + "-" + hex6(b);
  }

  function mint(device) {
    var clean = normalizeDevice(device);
    if (!clean) return null;
    var bucket = bucketNow();
    return {
      key: keyFor(clean, bucket),
      device: clean,
      bucket: bucket,
      expires: (bucket + 24) * 3600
    };
  }

  // proof that the checkpoint was opened from this page, for this device.
  // it is derived from the click time, so it stays the same even if the hour
  // rolls over while the checkpoint is open.
  function sign(device, started) {
    var bucket = Math.floor(started / 1000 / 3600);
    return keyFor("checkpoint|" + device + "|" + started, bucket);
  }

  window.FitzKey = {
    mint: mint,
    sign: sign,
    // exposed for testing the two implementations against each other
    keyAt: keyFor,
    normalizeDevice: normalizeDevice
  };
})();
