var _user$project$Native_WebSocket = function() {

function open(url)
{
    console.log("in outer native open")
	return _elm_lang$core$Native_Scheduler.nativeBinding(function(callback)
	{
        console.log("in native open", callback)

        // return callback(_elm_lang$core$Native_Scheduler.succeed(null));
		var id = setTimeout(function() {
            console.log("good morning!");
            callback(_elm_lang$core$Native_Scheduler.succeed(null));
			// callback(succeed(_elm_lang$core$Native_Utils.Tuple0));
		}, 1000);
		return function()
		{
            console.log("in the mysterious callback");
		};
	});
}

function send(socket, string)
{
	return _elm_lang$core$Native_Scheduler.nativeBinding(function(callback)
	{
        console.log("in send");
		var result =
			socket.readyState === WebSocket.OPEN
				? _elm_lang$core$Maybe$Nothing
				: _elm_lang$core$Maybe$Just({ ctor: 'NotOpen' });

		try
		{
			socket.send(string);
		}
		catch(err)
		{
			result = _elm_lang$core$Maybe$Just({ ctor: 'BadString' });
		}

		callback(_elm_lang$core$Native_Scheduler.succeed(result));
	});
}

function close(code, reason, socket)
{
	return _elm_lang$core$Native_Scheduler.nativeBinding(function(callback) {
        console.log("in close");
		try
		{
			socket.close(code, reason);
		}
		catch(err)
		{
			return callback(_elm_lang$core$Native_Scheduler.fail(_elm_lang$core$Maybe$Just({
				ctor: err.name === 'SyntaxError' ? 'BadReason' : 'BadCode'
			})));
		}
		callback(_elm_lang$core$Native_Scheduler.succeed(_elm_lang$core$Maybe$Nothing));
	});
}

function bytesQueued(socket)
{
	return _elm_lang$core$Native_Scheduler.nativeBinding(function(callback) {
        console.log("in bytesQueued");
		callback(_elm_lang$core$Native_Scheduler.succeed(socket.bufferedAmount));
	});
}

return {
	open: open,
	send: F2(send),
	close: F3(close),
	bytesQueued: bytesQueued
};

}();
