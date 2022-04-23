// Please see documentation at https://docs.microsoft.com/aspnet/core/client-side/bundling-and-minification
// for details on configuring this project to bundle and minify static web assets.

// Write your JavaScript code.
function CopySecret(id, name) {

	$.ajax({
		url: "/secrets/value?id=" + id,
		success: function (result) {

			var text = $("#" + name).text();
			if (text === "Done") {
				$("#" + name).text("Copy to Clipboard");
				$("#hd" + name).css('visibility', 'hidden');
				$("#h" + name).val('');
			} else {
				$("#" + name).text("Copying...");

				navigator.clipboard.writeText(result).then(() => {
					$("#" + name).text("Copied!");
					setTimeout(function () {
						$("#" + name).text(text);
					}, 5000);
				}, () => {

					$("#" + name).text("Done");
					try {

						$("#hd" + name).css('visibility', 'visible');
						$("#h" + name).val(result);

						setTimeout(function () {
							var id = "h" + name;
							document.getElementById(id).focus();
							document.getElementById(id).select();
						}, 500);

					} catch (e) {
						alert("Error: " + e);
					}
				});
			}
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