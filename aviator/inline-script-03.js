
(function(){
  const control = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aviatorControl;
  if(control){
    window.postMessage({source:"lumorax-aviator",type:"bridge-ready"}, "*");
    control.postMessage({action:"ready",hasState:Boolean(localStorage.getItem("lumorax_aviator_live_v2"))});
  }
  document.getElementById("iosBackToGames").addEventListener("click", function(){
    if(control) control.postMessage({action:"close"});
    window.location.href = "index.html";
  });
})();
