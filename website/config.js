/* fitz's stuff :: site config
   edit the values here, nothing else on the site needs to change. */
window.FITZ_CONFIG = {
  // where the site lives (used for canonical redirects back from the checkpoint)
  siteUrl: "https://fitzhub.vercel.app/",

  // main script the loadstring pulls
  scriptUrl: "https://raw.githubusercontent.com/sk1dd3d/fitzhub/refs/heads/main/main.lua",

  // key settings
  keyHours: 24,

  discord: "https://discord.gg/5pQCshrz6",

  /* the one checkpoint. paste your own linkvertise link here.
     set the linkvertise destination to:
       https://fitzhub.vercel.app/get-key.html?lv=1&t=theverysecretsecretive
     and put that same word in returnToken below. the key page only accepts a
     return that carries it, so people cannot just type the url themselves. */
  checkpointUrl: "https://link-center.net/10279779/rSnTuY6wcW1w",
  returnToken: "theverysecretsecretive"
};
