/* fitz's stuff :: site config
   edit the values here, nothing else on the site needs to change. */
window.FITZ_CONFIG = {
  // where the site lives (used for canonical redirects back from the checkpoint)
  siteUrl: "https://sk1dd3d.github.io/fitzhub/",

  // main script the loadstring pulls
  scriptUrl: "https://raw.githubusercontent.com/sk1dd3d/fitzhub/refs/heads/main/main.lua",

  // key settings
  keyHours: 24,

  discord: "https://discord.gg/5pQCshrz6",

  /* the one checkpoint. paste your own linkvertise link here.
     set the linkvertise destination to:
       https://sk1dd3d.github.io/fitzhub/get-key.html?lv=1&t=PICK_A_LONG_RANDOM_WORD
     and put that same word in returnToken below. the key page only accepts a
     return that carries it, so people cannot just type the url themselves. */
  checkpointUrl: "https://linkvertise.com/000000/fitz-hub-key",
  returnToken: "PICK_A_LONG_RANDOM_WORD"
};
