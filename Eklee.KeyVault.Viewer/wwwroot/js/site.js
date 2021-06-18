// Please see documentation at https://docs.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Write your JavaScript code.
function CopySecret(id, name) {

	$.ajax({
		url: "/secrets/value?id=" + id,
		success: function (result) {
			CopyToClipboard(result);
			var text = $("#" + name).text();
			$("#" + name).text("Copied!");

			setTimeout(function () {
				$("#" + name).text(text);
			}, 4000);
		},
		error: function (err) {
			if (err.status === 403) {
				alert("You do not have permission to view secret value for " + name + "!", true);
			} else {
				alert(JSON.stringify(err));
			}
		}
	});
}

function CopyToClipboard(val) {
	var hiddenClipboard = $('#_hiddenClipboard_');
	if (!hiddenClipboard.length) {
		$('body').append('<textarea readonly style="position:absolute;top: -9999px;" id="_hiddenClipboard_"></textarea>');
		hiddenClipboard = $('#_hiddenClipboard_');
	}
	hiddenClipboard.html(val);
	hiddenClipboard.select();
	document.execCommand('copy');
	document.getSelection().removeAllRanges();
	hiddenClipboard.remove();
}

$(function () {
	$('#notifyMsg').hide();
	$('#errNotifyMsg').hide();
});