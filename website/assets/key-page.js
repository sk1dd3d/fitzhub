/* fitz's stuff :: key page
   flow: device id -> checkpoint -> key. the checkpoint step only counts when
   it comes back to this page with ?lv=1 and a checkpoint that was opened from
   here at least a few seconds earlier. */
(function () {
  "use strict";

  var cfg = window.FITZ_CONFIG;
  var KEY = window.FitzKey;

  var els = {
    device: document.getElementById("device"),
    discord: document.getElementById("discordBtn"),
    discordLabel: document.getElementById("discordLabel"),
    checkpoint: document.getElementById("checkpointBtn"),
    hint: document.getElementById("checkpointHint"),
    generate: document.getElementById("generateBtn"),
    status: document.getElementById("status"),
    out: document.getElementById("keyOut"),
    value: document.getElementById("keyValue"),
    meta: document.getElementById("keyMeta"),
    copyKey: document.getElementById("copyKey"),
    pill1: document.getElementById("pill1"),
    pill2: document.getElementById("pill2"),
    pill3: document.getElementById("pill3")
  };

  var STORE = {
    device: "fitz_device",
    start: "fitz_checkpoint_start",
    token: "fitz_checkpoint_token",
    joined: "fitz_discord",
    key: "fitz_key_cache"
  };

  // a checkpoint that returns faster than this was never really opened
  var MIN_CHECKPOINT_MS = 5000;
  var MAX_CHECKPOINT_MS = 30 * 60 * 1000;

  var state = {
    device: null,
    joined: false,
    checkpoint: false
  };

  function read(name) {
    try { return localStorage.getItem(name); } catch (err) { return null; }
  }

  function write(name, value) {
    try { localStorage.setItem(name, value); } catch (err) { /* private mode */ }
  }

  function drop(name) {
    try { localStorage.removeItem(name); } catch (err) { /* private mode */ }
  }

  function setStatus(text, good) {
    els.status.textContent = text || "";
    els.status.classList.remove("good", "bad");
    if (good === true) els.status.classList.add("good");
    if (good === false) els.status.classList.add("bad");
  }

  function sign(device, started) {
    // ties the checkpoint return to this device and this exact click
    return KEY.sign(device, started);
  }

  function paint() {
    els.pill1.className = "step-pill " + (state.device ? "done" : "active");
    els.pill2.className = "step-pill " +
      (state.checkpoint ? "done" : state.device ? "active" : "");
    els.pill3.className = "step-pill " + (state.checkpoint ? "active" : "");

    els.checkpoint.disabled = !state.device;
    els.discordLabel.textContent = state.joined ? "discord joined" : "join the discord";
    els.discord.style.borderColor = state.joined ? "rgba(111, 211, 154, 0.4)" : "";

    if (state.checkpoint) {
      els.hint.textContent = "checkpoint done. generate your key below.";
    } else if (state.device) {
      els.hint.textContent = "next: the checkpoint and the discord step. the checkpoint brings you back here.";
    } else {
      els.hint.textContent = "enter your device id first, then finish the checkpoint and the discord step.";
    }

    var ready = Boolean(state.device && state.joined && state.checkpoint);
    els.generate.disabled = !ready;
    els.generate.style.opacity = ready ? "1" : "0.45";
    els.generate.style.cursor = ready ? "pointer" : "not-allowed";
    return ready;
  }

  function setDevice(raw) {
    var clean = KEY.normalizeDevice(raw);
    state.device = clean;
    if (clean) write(STORE.device, clean);
    paint();
    return clean;
  }

  function showKey(result) {
    els.value.textContent = result.key;
    els.meta.textContent = "expires " +
      new Date(result.expires * 1000).toLocaleString() +
      "  ·  device " + result.device;
    els.out.classList.add("show");
    els.pill3.className = "step-pill done";
  }

  function checkReturn() {
    var query = window.location.search || "";
    var flag = /(?:^|[?&])lv=1(?:&|$)/.test(query);
    var token = null;
    var match = /(?:^|[?&])t=([^&]+)/.exec(query);
    if (match) token = decodeURIComponent(match[1]);

    var started = Number(read(STORE.start) || 0);
    var proof = read(STORE.token);

    if (window.history && window.history.replaceState) {
      window.history.replaceState({}, "", window.location.pathname);
    }

    if (!flag) return false;

    // when a return token is configured it has to match the one set on the
    // checkpoint destination, so a hand typed ?lv=1 does not count
    if (cfg.returnToken && token !== cfg.returnToken) return false;
    if (!proof || !started || !state.device) return false;

    var elapsed = Date.now() - started;
    if (elapsed < MIN_CHECKPOINT_MS || elapsed > MAX_CHECKPOINT_MS) return false;

    var expected = sign(state.device, started);
    if (!expected || expected !== proof) return false;

    drop(STORE.start);
    drop(STORE.token);
    return true;
  }

  function generate() {
    if (!paint()) return;

    var result = KEY.mint(state.device);
    if (!result) {
      setStatus("that device id does not look right. copy it from the script menu.", false);
      return;
    }

    write(STORE.key, JSON.stringify(result));
    showKey(result);
    setStatus("key ready. paste it in the script.", true);
  }

  /* boot ------------------------------------------------------------- */

  var cached = null;
  try {
    var saved = JSON.parse(read(STORE.key) || "null");
    if (saved && saved.expires * 1000 > Date.now()) cached = saved;
    else drop(STORE.key);
  } catch (err) {
    drop(STORE.key);
  }

  state.joined = read(STORE.joined) === "1";
  setDevice((cached && cached.device) || read(STORE.device) || "");

  if (state.device) els.device.value = state.device;

  if (cached) {
    state.joined = true;
    state.checkpoint = true;
    paint();
    showKey(cached);
    setStatus("your last key is still valid, here it is again.", true);
  } else {
    state.checkpoint = checkReturn();
    paint();
    if (state.checkpoint) {
      setStatus("checkpoint confirmed. generate your key.", true);
    }
  }

  els.device.addEventListener("input", function () {
    if (cached) {
      // the old key stays on screen, but typing a new id starts a fresh run
      cached = null;
      drop(STORE.key);
    }
    setDevice(els.device.value);
    // a different device means the checkpoint has to be done again
    if (state.checkpoint) {
      state.checkpoint = false;
      paint();
      setStatus("device changed, do the checkpoint again.", false);
    }
  });

  els.discord.addEventListener("click", function () {
    state.joined = true;
    write(STORE.joined, "1");
    paint();
    setStatus("discord opened in a new tab.", true);
    window.open(cfg.discord, "_blank", "noopener");
  });

  els.checkpoint.addEventListener("click", function () {
    if (!state.device) return;
    var started = Date.now();
    write(STORE.start, String(started));
    write(STORE.token, sign(state.device, started));
    setStatus("taking you to the checkpoint...", true);
    // same tab on purpose: the checkpoint sends you straight back here, so
    // there is no second tab left showing a half finished page
    window.location.href = cfg.checkpointUrl;
  });

  els.generate.addEventListener("click", generate);

  els.copyKey.addEventListener("click", function () {
    var text = els.value.textContent.trim();
    if (!text) return;
    window.Site.copyText(text).then(function (ok) {
      setStatus(ok ? "key copied" : "copy failed, select the key manually", ok);
    });
  });

  var loader = document.getElementById("loader2");
  if (loader) {
    loader.style.cursor = "pointer";
    loader.title = "click to copy";
    loader.addEventListener("click", function () {
      window.Site.copyText(loader.textContent.trim()).then(function (ok) {
        setStatus(ok ? "script copied" : "copy failed", ok);
      });
    });
  }
})();
