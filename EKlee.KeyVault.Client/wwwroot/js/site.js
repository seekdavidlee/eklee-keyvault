window.clipboardCopy = {
	copyText: function (text) {
		return navigator.clipboard.writeText(text);
	}
};