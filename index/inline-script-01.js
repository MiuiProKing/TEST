
  try{
    const oledEnabled = (localStorage.getItem("lumorax_theme_enabled") ?? localStorage.getItem("luckyjet_oled_theme")) !== "off";
    const oledColor = localStorage.getItem("lumorax_theme_color") || localStorage.getItem("luckyjet_oled_color") || "#000000";
    document.documentElement.style.setProperty("--oled-bg", oledColor);
    if(oledEnabled) document.documentElement.classList.add("oled-theme");
  }catch(_){ document.documentElement.classList.add("oled-theme"); }
