// Please see documentation at https://docs.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Write your JavaScript code.
function CopySecret(id, name) {

	$.ajax({
		url: "/secrets/value?id=" + id,
		success: function (result) {
			try {
				navigator.clipboard.writeText(result);
				$("#" + name).text("Copied!");
			} catch {
				$("#h_" + name).style.visibility = "visible";
				$("#h_" + name).val(result);
				$("#" + name).text("Unable to copy. Please select and copy from below.");
			}

			var text = $("#" + name).text();
			setTimeout(function () {
				$("#" + name).text(text);
			}, 5000);
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

$(function () {
	$('#notifyMsg').hide();
	$('#errNotifyMsg').hide();
});