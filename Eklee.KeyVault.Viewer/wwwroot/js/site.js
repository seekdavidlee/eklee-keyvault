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
						$("#h" + name).focus(() => {
							$("#h" + name).select();
						});
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
const searchStartLength = 3;
$(function () {
	$('#notifyMsg').hide();
	$('#errNotifyMsg').hide();

	$("#searchText").on("keyup", function () {
		var searchText = $("#searchText").val();
		var length = searchText.length;
		if (length >= searchStartLength) {

			$("tr").each(function () {
				var tr = $(this);
				var name = tr.attr('name');
				if (name && name.length >= searchStartLength) {

					if (name.search(searchText) > -1) {
						tr.show();
					} else {
						tr.hide();
					}
				}
			});
		} else {
			$("tr").show();
		}
	});
});