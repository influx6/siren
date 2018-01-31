effect module WebsocketMedium where { command = WSCmd } exposing
    (..)

import Task
import WebSocket.LowLevel as WSL


type WSCmd msg
    = Connect String (Bool -> msg) (String -> msg) msg


type alias Msg
    = ()

type alias State
    = List WSL.WebSocket


cmdMap : (a -> b) -> WSCmd a -> WSCmd b
cmdMap f cmd =
    case cmd of
        Connect a b c d -> Connect a (f << b) (f << c) (f d)


init : Task.Task Never State
init = Debug.log ("ws init!") <| Task.succeed []


onEffects : Platform.Router msg Msg -> List (WSCmd msg) -> State -> Task.Task Never (State)
onEffects r cmds state =
    helper (List.map (\c -> dealWithCmd r c) cmds) state


helper : List (s -> Task.Task x s) -> s -> Task.Task x s
helper fs state =
    case fs of
        [] -> Task.succeed state
        f :: rest -> f state |> Task.andThen (helper rest)


dealWithCmd : Platform.Router msg Msg -> WSCmd msg -> State -> Task.Task Never (State)
dealWithCmd r cmd state =
    case cmd of
        Connect url onConnect onMesg onClose ->
            let
                cbMessage : WSL.WebSocket -> String -> Task.Task Never ()
                cbMessage ws payload = Platform.sendToApp r (onMesg payload)
                cbClose : { code : Int, reason : String, wasClean : Bool } -> Task.Task Never ()
                cbClose details = Platform.sendToApp r onClose
            in
                WSL.open url { onMessage = cbMessage, onClose = cbClose }
                    |> Task.andThen (
                        \ws -> Platform.sendToApp r (onConnect True)
                               |> Task.andThen (\_ -> Task.succeed ( ws :: state ))
                    )
                    |> Task.onError (\err -> Platform.sendToApp r (onConnect False) |> Task.andThen (\_ -> Task.succeed state))


onSelfMsg : Platform.Router msg Msg -> Msg -> State -> Task.Task Never (State)
onSelfMsg router msg state =
    Debug.log ("in onSelfMsg: " ++ toString msg) <| Task.succeed state


connect : String -> (Bool -> msg) -> (String -> msg) -> msg -> Cmd msg
connect url onConnect onMesg onClose =
    command <| Connect url onConnect onMesg onClose 
    
