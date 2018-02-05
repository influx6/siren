effect module Explicit
    where { command = WSCmd }
    exposing
        ( WebSocket
        , open
        )

import Task
import Time
import Process
import WebSocket.LowLevel as WSL


{-| An opaque websocket handle.
-}
type WebSocket
    = WS


type WSCmd msg
    = Open


cmdMap : (a -> b) -> WSCmd a -> WSCmd b
cmdMap f cmd =
    case cmd of
        Open -> Open


init : Task.Task Never ()
init =
    Task.succeed ()


onEffects : Platform.Router msg () -> List (WSCmd msg) -> () -> Task.Task Never ()
onEffects r cmds () =
    case cmds of
        [] -> Task.succeed ()
        [Open] -> Process.sleep (1 * Time.second)
        _ -> Debug.crash "hahaha"


onSelfMsg : Platform.Router msg () -> () -> () -> Task.Task Never ()
onSelfMsg router msg () =
    Task.succeed ()


open :
    String -> (Result String WebSocket -> msg) -> Cmd msg
open url onOpen =
    command <| Open

