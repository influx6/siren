effect module WebsocketMedium where { command = WSCmd } exposing
    ( open
    , send
    , WebSocket
    )

import Task
import WebSocket.LowLevel as WSL


type WebSocket = WS WSL.WebSocket


type WSCmd msg
    = Open String (Result String WebSocket -> msg) (String -> msg) (String -> msg)
    | Send WSL.WebSocket String (String -> msg)


type alias Msg
    = ()


cmdMap : (a -> b) -> WSCmd a -> WSCmd b
cmdMap f cmd =
    case cmd of
        Open a b c d -> Open a (f << b) (f << c) (f << d)
        Send a b c -> Send a b (f << c)


init : Task.Task Never ()
init = Task.succeed ()


onEffects : Platform.Router msg Msg -> List (WSCmd msg) -> () -> Task.Task Never ()
onEffects r cmds state =
    helper (List.map (\c -> dealWithCmd r c) cmds) state


helper : List (s -> Task.Task x s) -> s -> Task.Task x s
helper fs state =
    case fs of
        [] -> Task.succeed state
        f :: rest -> f state |> Task.andThen (helper rest)


dealWithCmd : Platform.Router msg Msg -> WSCmd msg -> () -> Task.Task Never ()
dealWithCmd r cmd state =
    case cmd of
        Open url onOpen onMesg onClose ->
            let
                cbMessage : WSL.WebSocket -> String -> Task.Task Never ()
                cbMessage ws payload = Platform.sendToApp r (onMesg payload)
                cbClose : { code : Int, reason : String, wasClean : Bool } -> Task.Task Never ()
                cbClose details = Platform.sendToApp r (onClose details.reason)
            in
                WSL.open url { onMessage = cbMessage, onClose = cbClose }
                    |> Task.andThen (
                        \ws -> Platform.sendToApp r (onOpen <| Ok <| WS ws)
                    )
                    |> Task.onError (\err -> Platform.sendToApp r (onOpen <| Err <| toString err)
                                        |> Task.andThen (\_ -> Task.succeed state)
                                    )
        Send ws msg onError ->
            WSL.send ws msg
                |> Task.andThen (\res -> case res of
                    Nothing -> Task.succeed ()
                    Just badsend -> Platform.sendToApp r (onError <| toString badsend)
                )
                


onSelfMsg : Platform.Router msg Msg -> Msg -> () -> Task.Task Never ()
onSelfMsg router msg state =
    Debug.log ("in onSelfMsg: " ++ toString msg) <| Task.succeed state


open : String -> (Result String WebSocket -> msg) -> (String -> msg) -> (String -> msg) -> Cmd msg
open url onOpen onMesg onClose =
    command <| Open url onOpen onMesg onClose 
    

send : WebSocket -> String -> (String -> msg) -> Cmd msg
send (WS ws) msg onError =
    command <| Send ws msg onError
