import Html exposing (Html, div, text, button)
import Html.Events exposing (onClick, onDoubleClick)
import Html.Attributes as Attr
import Http
import WebSocket
import Json.Decode as Decode
import Json.Encode as Encode

import Mpd


main =
  Html.program
    { init = init
    , view = view
    , update = update
    , subscriptions = subscriptions
    }

type alias Model = 
    { status : Mpd.Status
    , playlist : Mpd.Playlist
    , view : View
    , fileView : List Pane
    , artistView : List Pane
    }

init : (Model, Cmd Msg)
init =
  ( Model Mpd.newStatus Mpd.newPlaylist Playlist [rootPane] [artistPane]
  , Cmd.batch
    [ wsLoadDir rootPane.id
    , wsList artistPane.id "artists" "" ""
    ]
  )

rootPane : Pane
rootPane =
    { id = ""
    , title = "/"
    , entries = []
    }

artistPane : Pane
artistPane =
    { id = "artists"
    , title = "Artist"
    , entries = []
    }

type View
  = Playlist
  | FileBrowser 
  | ArtistBrowser

type Msg
  = PressPlay
  | PressPause
  | PressStop
  | PressPlayID String
  | PlaylistAdd String
  | PressRes (Result Http.Error String)
  | NewWSMessage String
  | Show View
  | AddFilePane String Pane -- AddFilePane after newpane
  | AddArtistPane String Pane (Cmd.Cmd Msg) -- AddArtistPane after newpane

type alias PaneEntry =
    { id : String
    , title : String
    , current : Bool
    , onClick : Maybe Msg
    , onDoubleClick : Maybe Msg
    }

type alias Pane =
    { id : String
    , title : String
    , entries : List PaneEntry
    }


update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
  case msg of
    PressPlay ->
      (model, doAction "play")

    PressPause ->
      (model, doAction "pause")

    PressStop ->
      (model, doAction "stop")

    PressPlayID e ->
      (model, doAction <| "track/" ++ e ++ "/play")

    PressRes (Ok newUrl) ->
      (model , Cmd.none)

    PressRes (Err _) ->
      (model, Cmd.none) -- TODO: log or something

    NewWSMessage m ->
      case Decode.decodeString Mpd.wsMsgDecoder m of
        Err e -> Debug.log ("json err: " ++ e) (model, Cmd.none)
        Ok s ->
            case s of
                Mpd.WSPlaylist p ->
                    ({ model | playlist = p }, Cmd.none)
                Mpd.WSStatus s -> 
                    ({ model | status = s }, Cmd.none)
                Mpd.WSInode s -> 
                    ({ model | fileView = setFilePane s model.fileView }, Cmd.none)
                Mpd.WSList s -> 
                    ({ model | artistView = setListPane s model.artistView }, Cmd.none)

    Show v ->
        -- TODO: update root if this is a file/artist viewer
        ({ model | view = v }, Cmd.none)

    AddFilePane after p ->
        ({ model | fileView = addPane model.fileView after p }
        , wsLoadDir p.id
        )

    AddArtistPane after p cmd ->
        ({ model | artistView = addPane model.artistView after p }
        , cmd
        )

    PlaylistAdd id ->
        ( model
        , wsPlaylistAdd id
        )


view : Model -> Html Msg
view model =
  div [Attr.class "mpd"]
    [ viewPlayer model
    , viewTabs model
    , viewView model
    , viewFooter
    ]

viewPlayer : Model -> Html Msg
viewPlayer model =
  let
    prettySong tr = tr.title ++ " by " ++ tr.artist
    song = prettySong <| Mpd.lookupPlaylist model.playlist model.status.songid
  in
  div [Attr.class "player"]
    [ button [ onClick PressPlay ] [ text "⏯" ]
    , button [ onClick PressPause ] [ text "⏸" ]
    , button [ onClick PressStop ] [ text "⏹" ]
    , text " - "
    , text <| "Currently: " ++ model.status.state ++ " "
    , text <| "Song: " ++ song ++ " "
    , text <| "Time: " ++ model.status.elapsed ++ "/" ++ model.status.time
    ]

viewTabs : Model -> Html Msg
viewTabs model =
  div [Attr.class "tabs"]
    [ button [ onClick <| Show Playlist ] [ text "playlist" ]
    , button [ onClick <| Show FileBrowser ] [ text "files" ]
    , button [ onClick <| Show ArtistBrowser ] [ text "artists" ]
    ]

viewView : Model -> Html Msg
viewView model =
  case model.view of
    Playlist -> viewViewPlaylist model
    FileBrowser -> viewViewFiles model
    ArtistBrowser -> viewViewArtists model
    
viewViewFiles : Model -> Html Msg
viewViewFiles model =
  div [Attr.class "nc"]
    <| List.map viewPane model.fileView

viewViewArtists : Model -> Html Msg
viewViewArtists model =
  div [Attr.class "nc"]
    <| List.map viewPane model.artistView

viewPane : Pane -> Html Msg
viewPane p =
  let
    viewLine e =
      div 
        (
          ( if e.current
              then [Attr.class "exp"]
              else [])
          ++ ( case e.onClick of
               Nothing -> []
               Just e -> [onClick e]
             )
          ++ ( case e.onDoubleClick of
               Nothing -> []
               Just e -> [onDoubleClick e]
             )
        )
        [ text e.title
        ]
  in
    div [] (
        Html.h1 [] [ text p.title ]   
        :: List.map viewLine p.entries
    )

viewViewPlaylist : Model -> Html Msg
viewViewPlaylist model =
  div [Attr.class "playlist"]
    [ div []
        ( List.map (\e -> div
                [ Attr.class (if model.status.songid == e.id then "current" else "")
                , onDoubleClick <| PressPlayID e.id
                ]
                [ text <| e.artist ++ " - " ++ e.title
                ]
            ) model.playlist
        )
    ]

viewFooter : Html Msg
viewFooter =
    Html.footer [] [ text "Footers are easy!" ]

subscriptions : Model -> Sub Msg
subscriptions model =
  WebSocket.listen wsURL NewWSMessage

wsURL : String
wsURL = "ws://localhost:6601/mpd/ws"


doAction : String -> Cmd Msg
doAction a =
  let
    url = "/mpd/" ++ a
  in
    Http.send PressRes (Http.getString url)


addPane : List Pane -> String -> Pane -> List Pane
addPane panes after new =
    case panes of
        [] -> []
        p :: tail -> if p.id == after
            then p :: [ new ]
            else p :: addPane tail after new

wsLoadDir : String -> Cmd msg
wsLoadDir id =
    WebSocket.send wsURL <| Encode.encode 0 <| Encode.object
        [ ("cmd", Encode.string "loaddir")
        , ("id", Encode.string id)
        ]

wsList : String -> String -> String -> String -> Cmd msg
wsList id what artist album =
    WebSocket.send wsURL <| Encode.encode 0 <| Encode.object
        [ ("cmd", Encode.string "list")
        , ("id", Encode.string id)
        , ("what", Encode.string what)
        , ("artist", Encode.string artist)
        , ("album", Encode.string album)
        ]

wsPlaylistAdd : String -> Cmd msg
wsPlaylistAdd id =
    WebSocket.send wsURL <| Encode.encode 0 <| Encode.object
        [ ("cmd", Encode.string "add")
        , ("id", Encode.string id)
        ]

setFilePane : Mpd.Inodes -> List Pane -> List Pane
setFilePane inodes panes =
    case panes of
        [] -> []
        p :: tail -> if p.id == inodes.id
            then {p | entries = toFilePaneEntries inodes} :: tail
            else p :: setFilePane inodes tail

toFilePaneEntries : Mpd.Inodes -> List PaneEntry
toFilePaneEntries inodes =
  let entry e = case e of
          Mpd.Dir id d -> PaneEntry id d False
                    (Just (AddFilePane inodes.id (newPane id d)))
                    (Just <| PlaylistAdd id)
          Mpd.File id f -> PaneEntry id f False
                    Nothing
                    (Just <| PlaylistAdd id)
  in
    List.map entry inodes.inodes


setListPane : Mpd.DBList -> List Pane -> List Pane
setListPane db panes =
    case panes of
        [] -> []
        p :: tail -> if p.id == db.id
            then {p | entries = toListPaneEntries db} :: tail
            else p :: setListPane db tail

toListPaneEntries : Mpd.DBList -> List PaneEntry
toListPaneEntries ls =
  let
    entry e = case e of
        Mpd.DBArtist artist ->
            PaneEntry artist artist False
            (Just <| AddArtistPane
                        ls.id
                        (newPane ("artist" ++ artist) artist)
                        (wsList ("artist" ++ artist) "artistalbums" artist "")
            )
            Nothing
        Mpd.DBAlbum artist album ->
            PaneEntry album album False
            (Just <| AddArtistPane
                        ls.id
                        (newPane ("album" ++ artist ++ album) album)
                        (wsList ("album" ++ artist ++ album) "araltracks" artist album)
            )
            Nothing
        Mpd.DBTrack artist album title ->
            PaneEntry title title False
            Nothing -- TODO: show song/file info pane
            Nothing
  in
    List.map entry ls.list

newPane : String -> String -> Pane
newPane id title =
    { id=id, title=title, entries=[] } 
