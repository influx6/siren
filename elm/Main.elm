module Main exposing (..)

import Color
import Dom.Scroll as Scroll
import FontAwesome
import Html exposing (Html, button, div, text)
import Html.Attributes as Attr
import Html.Events exposing (onClick, onDoubleClick)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Mpd
import Pane
import Task
import Time
import WebSocket


type alias MPane =
    Pane.Pane Msg


icon_play =
    FontAwesome.play_circle


icon_pause =
    FontAwesome.pause_circle


icon_stop =
    FontAwesome.stop_circle


icon_previous =
    FontAwesome.chevron_circle_left


icon_next =
    FontAwesome.chevron_circle_right


icon_replace =
    FontAwesome.play_circle


icon_add =
    FontAwesome.plus_circle


doubleClick =
    replaceAndPlay


main =
    Html.programWithFlags
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


type alias Model =
    { wsURL : String
    , status : Maybe Mpd.Status
    , statusT : Time.Time
    , playlist : Mpd.Playlist
    , view : View
    , fileView : List MPane
    , artistView : List MPane
    , now : Time.Time
    }


init : { wsURL : String } -> ( Model, Cmd Msg )
init flags =
    ( { wsURL = flags.wsURL
      , status = Nothing
      , statusT = 0
      , playlist = Mpd.newPlaylist
      , view = Playlist
      , fileView = [ rootPane ]
      , artistView = [ artistPane ]
      , now = 0
      }
    , Task.perform Tick Time.now
    )


rootPane : MPane
rootPane =
    Pane.newPane "root" "/" <| cmdLoadDir "root" ""


artistPane : MPane
artistPane =
    Pane.newPane "artists" "Artist" <| cmdList "artists" "artists" "" ""


type View
    = Playlist
    | FileBrowser
    | ArtistBrowser


type Msg
    = SendWS String -- encoded json
    | IncomingWSMessage String
    | Show View
    | AddFilePane String MPane -- AddFilePane after newpane
    | AddArtistPane String MPane -- AddArtistPane after newpane
    | Tick Time.Time
    | Noop


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        IncomingWSMessage m ->
            case Decode.decodeString Mpd.wsMsgDecoder m of
                Err e ->
                    Debug.log ("json err: " ++ e) ( model, Cmd.none )

                Ok s ->
                    case s of
                        Mpd.WSPlaylist p ->
                            ( { model | playlist = p }, Cmd.none )

                        Mpd.WSStatus s ->
                            ( { model | status = Just s, statusT = model.now }, Cmd.none )

                        Mpd.WSInode id s ->
                            ( { model | fileView = setFilePane id s model.fileView }, Cmd.none )

                        Mpd.WSList id s ->
                            ( { model | artistView = setListPane id s model.artistView }, Cmd.none )

                        Mpd.WSTrack id t ->
                            ( { model
                                | fileView = setTrackPane id t model.fileView
                                , artistView = setTrackPane id t model.artistView
                              }
                            , Cmd.none
                            )

                        Mpd.WSDatabase ->
                            ( model
                            , Cmd.batch
                                [ reloadFiles model
                                , reloadArtists model
                                ]
                            )

        Show Playlist ->
            ( { model | view = Playlist }, Cmd.none )

        Show FileBrowser ->
            ( { model | view = FileBrowser }
            , reloadFiles model
            )

        Show ArtistBrowser ->
            ( { model | view = ArtistBrowser }
            , reloadArtists model
            )

        AddFilePane after p ->
            ( { model | fileView = Pane.addPane model.fileView after p }
            , Cmd.batch
                [ scrollNC
                , wsSend model.wsURL p.update
                ]
            )

        AddArtistPane after p ->
            ( { model | artistView = Pane.addPane model.artistView after p }
            , Cmd.batch
                [ scrollNC
                , wsSend model.wsURL p.update
                ]
            )

        SendWS payload ->
            ( model
            , wsSend model.wsURL payload
            )

        Tick t ->
            ( { model | now = t }
            , Cmd.none
            )

        Noop ->
            ( model, Cmd.none )


view : Model -> Html Msg
view model =
    div [ Attr.class "mpd" ]
        [ viewHeader model
        , viewView model
        ]


viewPlayer : Model -> Html Msg
viewPlayer model =
    div [ Attr.class "player" ] <|
        case model.status of
            Nothing ->
                [ text "Loading..." ]

            Just status ->
                let
                    prettySong tr =
                        tr.title ++ " by " ++ tr.artist

                    song =
                        prettySong <| Mpd.lookupPlaylist model.playlist status.songid

                    realElapsed =
                        status.elapsed
                            + (case status.state of
                                "play" ->
                                    Time.inSeconds <| model.now - model.statusT

                                _ ->
                                    0
                              )

                    prettyTime =
                        prettySecs realElapsed ++ "/" ++ prettySecs status.duration

                    enbutton c i =
                        Html.a [ Attr.class "enabled", onClick c ] [ i Color.black 42 ]

                    disbutton i =
                        Html.a [] [ i Color.darkGrey 42 ]

                    buttons =
                        case status.state of
                            "play" ->
                                [ enbutton pressPause icon_pause
                                , enbutton pressStop icon_stop
                                ]

                            "pause" ->
                                [ enbutton pressPlay icon_play
                                , enbutton pressStop icon_stop
                                ]

                            "stop" ->
                                [ enbutton pressPlay icon_play
                                , disbutton icon_stop
                                ]

                            _ ->
                                []
                in
                buttons
                    ++ [ enbutton pressPrevious icon_previous
                       , enbutton pressNext icon_next
                       , Html.br [] []
                       , text <| "Currently: " ++ status.state ++ " "
                       , Html.br [] []
                       ]
                    ++ (if status.state == "pause" || status.state == "play" then
                            [ text <| "Song: " ++ song ++ " "
                            , Html.br [] []
                            , text <| "Time: " ++ prettyTime
                            , Html.br [] []
                            ]
                        else
                            []
                       )


viewHeader : Model -> Html Msg
viewHeader model =
    let
        count =
            " (" ++ (toString <| List.length model.playlist) ++ ")"
        tab what t =
            Html.a
                [ onClick <| Show what
                , Attr.class <| "tab " ++ (if model.view == what then "curr" else "")
                ] [ text t ]
            
    in
    div [ Attr.class "header" ]
        [ Html.a
            [ Attr.class "title"
            , onClick <| Show Playlist
            , Attr.title "Siren"
            ] [ text "[Siren]" ]
        , tab Playlist <| "Playlist" ++ count
        , tab FileBrowser "Files"
        , tab ArtistBrowser "Artists"
        ]


viewView : Model -> Html Msg
viewView model =
    case model.view of
        Playlist ->
            viewPlaylist model

        FileBrowser ->
            viewPanes model.fileView

        ArtistBrowser ->
            viewPanes model.artistView



viewPanes : List MPane -> Html Msg
viewPanes ps =
    div [ Attr.class "nc", Attr.id "nc" ] <|
        List.concat <|
            List.map viewPane ps


viewPane : MPane -> List (Html Msg)
viewPane p =
    let
        viewEntry : Pane.Entry Msg -> Html Msg
        viewEntry e =
            div
                (List.filterMap identity
                    [ if p.current == Just e.id then
                        Just <| Attr.class "exp"
                      else
                        Nothing
                    , Maybe.map onClick e.onClick
                    , case e.selection of
                        Nothing ->
                            Nothing

                        Just p ->
                            Just <| onDoubleClick <| doubleClick p
                    ]
                )
                [ text e.title
                ]

        viewBody : Pane.Body Msg -> List (Html Msg)
        viewBody b =
            case b of
                Pane.Plain a ->
                    List.singleton a

                Pane.Entries es ->
                    List.map viewEntry es

        playlists : List String
        playlists =
            case p.body of
                Pane.Plain a ->
                    []

                Pane.Entries es ->
                    List.filterMap .selection <|
                        List.filter (\e -> p.current == Just e.id) es
    in
    [ div [ Attr.class "title", Attr.title p.title ]
        [ text p.title ]
    , div [ Attr.class "pane" ] <|
        viewBody p.body
    , div [ Attr.class "footer" ] <|
        case playlists of
            [] ->
                []

            h :: _ ->
                [ Html.button [ onClick <| SendWS h ] [ text "add sel to playlist" ]
                , Html.button [ onClick <| replaceAndPlay h ] [ text "play sel" ]
                ]

    -- [ Html.a [ Attr.title "add to playlist"] [ icon_add Color.black 24 ]
    -- , Html.a [ Attr.title "replace playlist with ..." ] [ icon_replace Color.black 24 ]
    -- ]
    ]


viewPlaylist : Model -> Html Msg
viewPlaylist model =
    let
        col cl txt =
            div [ Attr.class cl ] [ text txt ]
    in
    div [ Attr.class "playlistwrap" ]
        [ div [ Attr.class "playlist" ]
            (List.map
                (\e ->
                    let
                        current =
                            case model.status of
                                Nothing ->
                                    False

                                Just s ->
                                    s.songid == e.id

                        t =
                            e.track
                    in
                    div
                        [ Attr.class
                            (if current then
                                "current"
                             else
                                ""
                            )
                        , onDoubleClick <| pressPlayID e.id
                        ]
                        [ col "track" t.track
                        , col "title" t.title
                        , col "artist" t.artist
                        , col "album" t.album
                        , col "dur" <| prettySecs t.duration
                        ]
                )
                model.playlist
            )
        , div [ Attr.class "commands" ]
            [ button [ onClick <| pressClear ] [ text "clear playlist" ]
            ]
        , viewPlayer model
        ]


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ WebSocket.listen model.wsURL IncomingWSMessage
        , Time.every Time.second Tick
        ]


wsSend : String -> String -> Cmd Msg
wsSend wsURL o =
    WebSocket.send wsURL o


cmdLoadDir : String -> String -> String
cmdLoadDir id dir =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string "loaddir" )
            , ( "id", Encode.string id )
            , ( "file", Encode.string dir )
            ]


cmdPlay : String
cmdPlay =
    buildWsCmd "play"


pressPlay : Msg
pressPlay =
    SendWS cmdPlay


cmdStop : String
cmdStop =
    buildWsCmd "stop"


pressStop : Msg
pressStop =
    SendWS cmdStop


cmdPause : String
cmdPause =
    buildWsCmd "pause"


pressPause : Msg
pressPause =
    SendWS cmdPause


cmdClear : String
cmdClear =
    buildWsCmd "clear"


pressClear : Msg
pressClear =
    SendWS cmdClear


pressPlayID : String -> Msg
pressPlayID id =
    SendWS <| buildWsCmdID "playid" id


pressPrevious : Msg
pressPrevious =
    SendWS <| buildWsCmd "previous"


pressNext : Msg
pressNext =
    SendWS <| buildWsCmd "next"


cmdPlaylistAdd : String -> String
cmdPlaylistAdd id =
    buildWsCmdID "add" id


cmdList : String -> String -> String -> String -> String
cmdList id what artist album =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string "list" )
            , ( "id", Encode.string id )
            , ( "what", Encode.string what )
            , ( "artist", Encode.string artist )
            , ( "album", Encode.string album )
            ]


cmdTrack : String -> String -> String
cmdTrack id file =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string "track" )
            , ( "id", Encode.string id )
            , ( "file", Encode.string file )
            ]


replaceAndPlay : String -> Msg
replaceAndPlay v =
    SendWS <|
        cmdClear
            ++ v
            ++ cmdPlay


cmdFindAdd : String -> String -> String -> String
cmdFindAdd artist album track =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string "findadd" )
            , ( "artist", Encode.string artist )
            , ( "album", Encode.string album )
            , ( "track", Encode.string track )
            ]


buildWsCmd : String -> String
buildWsCmd cmd =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string cmd )
            ]


buildWsCmdID : String -> String -> String
buildWsCmdID cmd id =
    Encode.encode 0 <|
        Encode.object
            [ ( "cmd", Encode.string cmd )
            , ( "id", Encode.string id )
            ]


setFilePane : String -> List Mpd.Inode -> List MPane -> List MPane
setFilePane paneid inodes panes =
    let
        body =
            Pane.Entries <| toFilePaneEntries paneid inodes
    in
    Pane.setBody body paneid panes


toFilePaneEntries : String -> List Mpd.Inode -> List (Pane.Entry Msg)
toFilePaneEntries paneid inodes =
    let
        entry e =
            case e of
                Mpd.Dir id title ->
                    let
                        pid =
                            "dir" ++ id
                    in
                    Pane.Entry pid
                        title
                        (Just <|
                            AddFilePane paneid <|
                                Pane.newPane pid title (cmdLoadDir pid id)
                        )
                        (Just <| cmdPlaylistAdd id)

                Mpd.File id name ->
                    let
                        pid =
                            "dir" ++ id
                    in
                    Pane.Entry pid
                        name
                        (Just <| AddFilePane paneid (filePane pid id name))
                        (Just <| cmdPlaylistAdd id)
    in
    List.map entry inodes


setListPane : String -> List Mpd.DBEntry -> List MPane -> List MPane
setListPane paneid db panes =
    let
        body =
            Pane.Entries <| toListPaneEntries paneid db
    in
    Pane.setBody body paneid panes


toListPaneEntries : String -> List Mpd.DBEntry -> List (Pane.Entry Msg)
toListPaneEntries parentid ls =
    let
        entry e =
            case e of
                Mpd.DBArtist artist ->
                    let
                        id =
                            "artist" ++ artist

                        add =
                            cmdFindAdd artist "" ""
                    in
                    Pane.Entry id
                        artist
                        (Just <|
                            AddArtistPane
                                parentid
                                (Pane.newPane id artist (cmdList id "artistalbums" artist ""))
                        )
                        (Just add)

                Mpd.DBAlbum artist album ->
                    let
                        id =
                            "album" ++ artist ++ album

                        add =
                            cmdFindAdd artist album ""
                    in
                    Pane.Entry id
                        album
                        (Just <|
                            AddArtistPane
                                parentid
                                (Pane.newPane id album (cmdList id "araltracks" artist album))
                        )
                        (Just add)

                Mpd.DBTrack artist album title id track ->
                    let
                        pid =
                            "track" ++ id

                        -- TODO: use "add file" ?
                        add =
                            cmdFindAdd artist album title
                    in
                    Pane.Entry pid
                        (track ++ " " ++ title)
                        (Just <|
                            AddArtistPane
                                parentid
                                (filePane pid id title)
                        )
                        (Just add)
    in
    List.map entry ls


setTrackPane : String -> Mpd.Track -> List MPane -> List MPane
setTrackPane paneid track panes =
    let
        body =
            Pane.Plain <| toPane track
    in
    Pane.setBody body paneid panes


reloadFiles : Model -> Cmd Msg
reloadFiles m =
    Cmd.batch <|
        List.map (\p -> wsSend m.wsURL p.update) m.fileView


reloadArtists : Model -> Cmd Msg
reloadArtists m =
    Cmd.batch <|
        List.map (\p -> wsSend m.wsURL p.update) m.artistView


scrollNC : Cmd Msg
scrollNC =
    Task.attempt (\_ -> Noop) <| Scroll.toRight "nc"


prettySecs : Float -> String
prettySecs secsf =
    let
        secs =
            round secsf

        m =
            secs // 60

        s =
            secs % 60
    in
    toString m ++ ":" ++ (String.padLeft 2 '0' <| toString s)


filePane : String -> String -> String -> MPane
filePane paneid fileid name =
    let
        p =
            Pane.newPane paneid name (cmdTrack paneid fileid)

        body : Pane.Body Msg
        body =
            Pane.Plain <| Html.text "..."
    in
    { p | body = body }


toPane : Mpd.Track -> Html Msg
toPane t =
    Html.div []
        [ FontAwesome.music Color.black 12
        , text <| " " ++ t.title
        , Html.br [] []
        , text <| "artist: " ++ t.artist
        , Html.br [] []
        , text <| "album: " ++ t.album
        , Html.br [] []
        , text <| "track: " ++ t.track
        , Html.br [] []
        , text <| "duration: " ++ prettySecs t.duration
        , Html.br [] []
        ]
