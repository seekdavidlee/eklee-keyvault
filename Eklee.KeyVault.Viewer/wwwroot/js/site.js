// Please see documentation at https://docs.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Write your JavaScript code.
function CopySecret(id, name) {

	$.ajax({
		url: "/secrets/value?id=" + id,
		success: function (result) {

			$("#" + name).text("Copying...");

			navigator.clipboard.writeText(result).then(() => {
				$("#" + name).text("Copied!");

				var text = $("#" + name).text();
				setTimeout(function () {
					$("#" + name).text(text);
				}, 5000);
			}, () => {

				$("#" + name).text("Unable to copy. Please select and copy from below.");
				try {

					$("#h" + name).css('visibility', 'visible');
					$("#h" + name).val(result);

					var text = $("#" + name).text();
					setTimeout(function () {
						$("#" + name).text(text);
					}, 5000);
				} catch (e) {
					alert("Error: " + e);
				}
			});
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