// Which apps the Apps tab suggests removing, and which it never touches.
// Adding a brand? Send package names with a short description each.

/// Preinstalled extras that are safe to remove. They can be restored from Removed.
let bloat = [
    "com.tcl.esticker": "Store demo stickers",
    "com.tcl.exhibit": "Store demo mode",
    "com.tcl.waterfall.overseas": "TCL recommendations feed",
    "com.tcl.channelplus": "TCL Channel (free channels with ads)",
    "com.tcl.messagebox": "TCL promo messages",
    "com.tcl.usercenter": "TCL account",
    "com.tcl.logkit": "TCL log collection",
    "com.tcl.ocean.instructions": "Built-in manual",
    "com.tcl.repairguide": "Repair guide",
    "com.tcl.smartalexa": "Alexa link",
    "com.tcl.hotelmenu": "Hotel mode",
    "com.google.android.feedback": "Google feedback reporter",
    "com.android.tv.feedbackconsent": "Feedback consent",
    "com.google.android.play.games": "Play Games",
    "com.android.adservices.api": "Android ad services",
    "com.android.ondevicepersonalization.services": "Ad personalisation",
    "com.android.federatedcompute.services": "Usage learning for ads",
    "tv.mopa.ginga": "Brazil interactive TV",
]

/// Names that look like ads or tracking, suggested on top of `bloat`.
@MainActor let likelyAds = try! Regex(#"(^|\.)(ads?|advert\w*|analytic\w*|track\w*|acr\w*|samba\w*|promo\w*|recommend\w*|feedback\w*|log\w*)(\.|$)"#)

/// Apps the TV can't do without: settings, home screen, keyboard, network, adb itself.
/// Matched by name, which covers TCL and Google TV.
@MainActor let protected = try! Regex(
    #"^android$|systemui|settings|launcher|packageinstaller|permissioncontroller|inputmethod|keyboard|gms|gsf"#
    + #"|setupwizard|provision|bluetooth|wifi|networkstack|tethering|com\.android\.shell|webview|framework|providers"#
    + #"|tv\.tuner|media\.tv|^com\.tcl\.(tv|tvinput|systemserver|globalkeyoverlay|initsetup|providers\.config)$|^com\.tvos$"#
    + #"|remote\.service|vending|ext\.services|setupwraith|mediashell|katniss|tvlauncher|intentresolver|overlay|rro_"#)
