/* fitz's stuff :: shared page helpers */
(function () {
  "use strict";

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).then(function () { return true; }).catch(function () {
        return legacyCopy(text);
      });
    }
    return Promise.resolve(legacyCopy(text));
  }

  function legacyCopy(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (err) { ok = false; }
    document.body.removeChild(area);
    return ok;
  }

  function flash(el, text, good) {
    if (!el) return;
    el.textContent = text;
    el.classList.remove("good", "bad");
    el.classList.add(good ? "good" : "bad");
  }

  function copyButton(buttonId, sourceId, statusId, message) {
    var button = document.getElementById(buttonId);
    if (!button) return;
    button.addEventListener("click", function () {
      var source = document.getElementById(sourceId);
      if (!source) return;
      copyText(source.textContent.trim()).then(function (ok) {
        flash(document.getElementById(statusId), ok ? message : "copy failed, select the text manually", ok);
      });
    });
  }

  window.Site = {
    copyText: copyText,
    flash: flash,
    copyButton: copyButton
  };
})();
