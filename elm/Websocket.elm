effect module Websocket where { command = WSCmd } exposing
    (..)

import Task
import WebSocket.LowLevel as WSL

type WSCmd msg
    = Blah

type State msg
    = MoreBlah

type Msg
    = AllTheBlah


init : Task.Task Never (State msg)
init = Debug.log ("ws init!") <| Task.succeed MoreBlah


cmdMap : (a -> b) -> WSCmd a -> WSCmd b
cmdMap f = always Blah


onEffects : Platform.Router msg Msg -> List (WSCmd msg) -> State msg -> Task.Task Never (State msg)
onEffects r msgs state =
    Debug.log ("in onEffects: " ++ toString msgs) <| Task.succeed state


onSelfMsg : Platform.Router msg Msg -> Msg -> State msg -> Task.Task Never (State msg)
onSelfMsg router msg state =
    Debug.log ("in onSelfMsg: " ++ toString msg) <| Task.succeed state


onMessage : WSL.WebSocket -> String -> Task.Task Never ()
onMessage _ msg =
    -- Platform.sendToApp
    Debug.crash <| "onMessage:" ++ msg


onClose : { code : Int, reason : String, wasClean : Bool } -> Task.Task Never ()
onClose m = Debug.crash <| "onClose!!!1!" ++ toString m


connect : String -> Task.Task WSL.BadOpen WSL.WebSocket
connect url =
    WSL.open url {onMessage = onMessage, onClose = onClose}

