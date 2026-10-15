// The install block's Copy button, as on the landing page.
(function(){
  var b = document.getElementById('copy');
  if (!b) return;
  b.addEventListener('click', function(){
    try { navigator.clipboard.writeText(document.getElementById('cmd').textContent).then(function(){ b.textContent='Copied'; setTimeout(function(){ b.textContent='Copy'; },1500); }); } catch(e){}
  });
})();
