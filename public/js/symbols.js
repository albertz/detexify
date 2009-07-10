// requires canvassify, mathtex

$(function(){
  $('#spinner').show();  
  $.getJSON("/symbols", function(json) {
    json.sort(function(a,b){ return (''+a.command).localeCompare(''+b.command); })
    populateSymbolList(json);
    latex.init();
    // setup training
    $('#symbols li .symbol img')
      .wrap('<a href="#"></a>')
      .tooltip({ tip: '#traintip' })
      .click(function(){
        $(this).tooltip(0).hide();
        if ($('#trainingli').is(":hidden")) {
          $('#trainingli').prev().removeClass('active');
          $('#trainingli').insertAfter($(this).closest("li")).slideDown('slow');
          $('#trainingli').prev().addClass('active');
        } else {
          var that = this;
          $('#trainingli').prev().removeClass('active');
          $('#trainingli').slideUp('slow', function(){
            $(this).insertAfter($(that).closest("li")).slideDown('slow');
            $('#trainingli').prev().addClass('active');
          });
        }
        return false;
        });
    
    // push the canvas inside the symbol list
    $('#trainingarea').appendTo('#symbols').wrap('<li id="trainingli"></li>').show();
    $('#spinner').hide();
    });

  });