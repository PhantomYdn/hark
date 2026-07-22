// ==UserScript==
// @name         Hark — auto-record Google Meet
// @namespace    hark
// @version      0.1.0
// @description  Auto-record Google Meet calls via the hark remote-control agent, and mirror your Meet mic mute to the recording.
// @match        https://meet.google.com/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @run-at       document-idle
// @downloadURL  https://raw.githubusercontent.com/PhantomYdn/hark/main/examples/hark-meet.user.js
// @updateURL    https://raw.githubusercontent.com/PhantomYdn/hark/main/examples/hark-meet.user.js
// ==/UserScript==

// Records every Google Meet call automatically: it starts a capture when you
// join and stops it when you leave, naming the file from the meeting title and
// date. While recording it also mirrors your Meet microphone mute to the
// recording (one-way, Meet → hark), so muting yourself in Meet silences only the
// mic in the capture (the call audio keeps recording; the timeline is preserved).
//
// Start the agent first, e.g. `hark --remote-control 8473 -C ~/Recordings`
// (or `brew services start hark`), with a working engine/model if you want
// transcripts. See docs/remote-control.md.

(function () {
  "use strict";

  const AGENT = "http://127.0.0.1:8473";
  const TOKEN = ""; // set if the agent uses $HARK_REMOTE_TOKEN

  let recording = false;
  let hasMic = true; // whether the active session includes a mic (mix/mic-only)
  let lastMuted = null; // last mute state mirrored to the agent (null = unknown)
  let micObserver = null;

  function post(path, body) {
    const headers = { "Content-Type": "application/json" };
    if (TOKEN) headers["Authorization"] = "Bearer " + TOKEN;
    GM_xmlhttpRequest({
      method: "POST",
      url: AGENT + path,
      headers,
      data: body ? JSON.stringify(body) : "",
      onload: (r) => console.log("[hark]", path, r.status, r.responseText),
      onerror: (e) => console.warn("[hark] agent unreachable", e),
    });
  }

  function fileBase() {
    const stamp = new Date()
      .toISOString()
      .slice(0, 16)
      .replace("T", "-")
      .replace(":", "");
    const title = (document.title || "Meet")
      .replace(/^Meet\s*[-–—]\s*/, "")
      .replace(/[^\w.-]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 60) || "meeting";
    return `Meet-${title}-${stamp}`;
  }

  // Heuristic: the in-call UI shows a "Leave call" control.
  function inCall() {
    return !!document.querySelector(
      '[aria-label*="Leave call" i], [aria-label*="Leave meeting" i]'
    );
  }

  // Meet's mic toggle carries `data-is-muted`; disambiguate from the camera
  // button by requiring "microphone" in the aria-label. Heuristic — Google
  // changes Meet's DOM over time, like the "Leave call" selector above.
  function micButton() {
    return (
      document.querySelector(
        '[role="button"][data-is-muted][aria-label*="microphone" i]'
      ) ||
      document.querySelector(
        '[aria-label*="Turn on microphone" i], [aria-label*="Turn off microphone" i]'
      )
    );
  }

  // true = muted, false = live, null = unknown (button not found).
  function micMuted() {
    const b = micButton();
    if (!b) return null;
    if (b.hasAttribute("data-is-muted")) {
      return b.getAttribute("data-is-muted") === "true";
    }
    // aria-label "Turn on microphone" means the mic is currently off (muted).
    return /turn on microphone/i.test(b.getAttribute("aria-label") || "");
  }

  // Mirror the current Meet mic state to the agent when it changes. The agent's
  // /mute and /unmute are idempotent, but we cache the last state to avoid spam.
  function syncMute() {
    if (!recording || !hasMic) return;
    const m = micMuted();
    if (m === null || m === lastMuted) return;
    lastMuted = m;
    post(m ? "/mute" : "/unmute");
  }

  // Watch the mic button so a toggle mirrors near-instantly, re-attaching if
  // Meet rebuilds the button. tick() below is the periodic fallback.
  function watchMic() {
    const b = micButton();
    if (!b) return;
    if (micObserver && micObserver._node === b) return; // already watching it
    if (micObserver) micObserver.disconnect();
    micObserver = new MutationObserver(syncMute);
    micObserver._node = b;
    micObserver.observe(b, {
      attributes: true,
      attributeFilter: ["data-is-muted", "aria-label"],
    });
  }

  function tick() {
    const active = inCall();
    if (active && !recording) {
      recording = true;
      const base = fileBase();
      const body = {
        system: true,
        mix: true,
        audio: base + ".m4a",
        transcript: base + ".srt",
        speakers: true,
        muted: micMuted() === true, // start muted if you joined muted
      };
      // A session has a mic when mixing, or when neither system nor apps is set.
      hasMic = !!body.mix || (!body.system && !(body.apps && body.apps.length));
      lastMuted = body.muted;
      post("/start", body);
    } else if (!active && recording) {
      recording = false;
      lastMuted = null;
      if (micObserver) {
        micObserver.disconnect();
        micObserver = null;
      }
      post("/stop");
    }
    // While in a call: keep the observer attached and re-check as a fallback.
    if (active) {
      watchMic();
      syncMute();
    }
  }

  setInterval(tick, 2000);
  window.addEventListener("beforeunload", () => {
    if (recording) post("/stop");
  });
})();
