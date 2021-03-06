module Main exposing (..)

import Decode
import Dom.Scroll as Scroll
import Encode
import Explicit as Explicit
import FontAwesome.Regular as Icon
import FontAwesome.Solid as Solid
import Html exposing (Html, button, div, text)
import Html.Attributes as Attr
import Html.Events as Events
import Html.Lazy as Lazy
import Http
import Json.Decode as Json
import Mpd exposing (ArtistMode(..), WSCmd(..))
import Pane
import Platform
import Process
import Task
import Time


type alias MPane =
    Pane.Pane Msg


icon_play =
    Solid.play_circle


icon_pause =
    Solid.pause_circle


icon_stop =
    Solid.stop_circle


icon_previous =
    Solid.chevron_circle_left


icon_next =
    Solid.chevron_circle_right


main =
    Html.programWithFlags
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


type Dragging
    = Dragging SliderType DragState Float
    | NotDragging


type SliderType
    = SliderSeek
    | SliderVolume


type DragState
    = Drag
    | Wait


type alias Model =
    { wsURL : String
    , config : Maybe Mpd.Config
    , status : Maybe Mpd.Status
    , statusT : Time.Time
    , playlist : Mpd.Playlist
    , view : View
    , fileView : List MPane
    , artistView : List MPane
    , albumartistView : List MPane
    , now : Time.Time
    , dragging : Dragging
    , conn : Maybe Explicit.WebSocket
    , mpdOnline : Bool
    }


init : { wsURL : String } -> ( Model, Cmd Msg )
init flags =
    ( { wsURL = flags.wsURL
      , config = Nothing
      , status = Nothing
      , statusT = 0
      , playlist = Mpd.newPlaylist
      , view = Playlist
      , fileView = [ fileRootPane ]
      , artistView = [ artistRootPane Artist ]
      , albumartistView = [ artistRootPane Albumartist ]
      , now = 0
      , dragging = NotDragging
      , conn = Nothing
      , mpdOnline = False
      }
    , Cmd.batch
        [ Task.perform Tick Time.now
        , connect flags.wsURL
        ]
    )


connect : String -> Cmd Msg
connect url =
    Explicit.open url
        { onOpen = WSOpen
        , onMessage = WSMessage
        , onClose = WSDisconnect
        }


fileRootPane : MPane
fileRootPane =
    Pane.new "root" (Pane.loading "/") <| Mpd.encodeCmd <| CmdLoadDir "root" ""


artistRootPane : ArtistMode -> MPane
artistRootPane mode =
    let
        ( id, title ) =
            case mode of
                Artist ->
                    ( "artist", "Artist" )

                Albumartist ->
                    ( "albumartist", "Albumartist" )
    in
    Pane.new id (Pane.loading title) <|
        Mpd.encodeCmd <|
            CmdList id
                mode
                { what = "artists"
                , artist = ""
                , album = ""
                }


type View
    = Playlist
    | FileBrowser
    | ArtistBrowser ArtistMode


type Msg
    = SendWS String -- encoded EDN
    | Show View
    | AddFilePane String MPane -- AddFilePane after newpane
    | AddArtistPane ArtistMode String MPane -- AddArtistPane artistmode after newpane
    | Tick Time.Time
    | Seek String Float
    | StartDrag SliderType Float
    | SetVolume Float
    | Connect
    | WSOpen (Result String Explicit.WebSocket)
    | WSMessage String
    | WSDisconnect String
    | Noop


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        addPane v after p =
            let
                nv =
                    Pane.addPane v after p
            in
            List.map (\( p, c ) -> { p | body = paneFooter p.body c }) (withCurrent nv)
    in
    case msg of
        WSMessage m ->
            case Decode.decodeString Mpd.wsMsgDecoder m of
                Err e ->
                    Debug.log ("decoding err: " ++ e ++ ": " ++ m) ( model, Cmd.none )

                Ok s ->
                    case s of
                        Mpd.WSConnection mpd ->
                            ( { model | mpdOnline = mpd }
                            , case mpd of
                                True ->
                                    reloadViews model

                                False ->
                                    Cmd.none
                            )

                        Mpd.WSPlaylist p ->
                            ( { model | playlist = p }, Cmd.none )

                        Mpd.WSConfig c ->
                            ( { model | config = Just c }, Cmd.none )

                        Mpd.WSStatus s ->
                            ( { model
                                | status = Just s
                                , dragging =
                                    case model.dragging of
                                        Dragging _ Wait _ ->
                                            NotDragging

                                        _ ->
                                            model.dragging
                                , statusT = model.now
                              }
                            , Cmd.none
                            )

                        Mpd.WSInode id s ->
                            ( { model | fileView = setFilePane id s model.fileView }, Cmd.none )

                        Mpd.WSList mode id s ->
                            let
                                m =
                                    case mode of
                                        Artist ->
                                            { model | artistView = setListPane id Artist s model.artistView }

                                        Albumartist ->
                                            { model | albumartistView = setListPane id Albumartist s model.albumartistView }
                            in
                            ( m, Cmd.none )

                        Mpd.WSTrack id t ->
                            ( { model
                                | fileView = setTrackPane id t model.fileView
                                , artistView = setTrackPane id t model.artistView
                                , albumartistView = setTrackPane id t model.albumartistView
                              }
                            , Cmd.none
                            )

                        Mpd.WSDatabase ->
                            ( model
                            , reloadViews model
                            )

        Show Playlist ->
            ( { model | view = Playlist }, Cmd.none )

        Show FileBrowser ->
            ( { model | view = FileBrowser }
            , Cmd.none
            )

        Show (ArtistBrowser a) ->
            ( { model | view = ArtistBrowser a }
            , Cmd.none
            )

        AddFilePane after p ->
            ( { model | fileView = addPane model.fileView after p }
            , Cmd.batch
                [ scrollNC
                , wsSend model.conn p.update
                ]
            )

        AddArtistPane mode after p ->
            let
                m =
                    case mode of
                        Artist ->
                            { model | artistView = addPane model.artistView after p }

                        Albumartist ->
                            { model | albumartistView = addPane model.albumartistView after p }
            in
            ( m
            , Cmd.batch
                [ scrollNC
                , wsSend model.conn p.update
                ]
            )

        SendWS payload ->
            ( model
            , wsSend model.conn payload
            )

        Tick t ->
            ( { model | now = t }
            , Cmd.none
            )

        Seek id s ->
            case model.dragging of
                Dragging SliderSeek Drag _ ->
                    ( { model | dragging = Dragging SliderSeek Wait s }
                    , wsSend model.conn <| Mpd.encodeCmd <| CmdSeek id s
                    )

                Dragging SliderSeek _ _ ->
                    ( { model | dragging = NotDragging }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        SetVolume v ->
            case model.dragging of
                Dragging SliderVolume Drag _ ->
                    ( { model | dragging = Dragging SliderVolume Wait v }
                    , wsSend model.conn <| Mpd.encodeCmd <| CmdSetVolume v
                    )

                Dragging SliderVolume _ _ ->
                    ( { model | dragging = NotDragging }
                    , Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        StartDrag slider value ->
            ( { model | dragging = Dragging slider Drag value }, Cmd.none )

        Connect ->
            ( model, connect model.wsURL )

        WSOpen (Ok ws) ->
            ( { model | conn = Just ws }, Cmd.none )

        WSOpen (Err err) ->
            ( { model
                | conn = Debug.log ("ws conn error: " ++ err) Nothing
                , mpdOnline = False
              }
            , Task.perform (always Connect) <| Process.sleep (5 * Time.second)
            )

        WSDisconnect reason ->
            ( { model
                | conn = Debug.log ("ws disconnected, reason: " ++ reason) Nothing
                , mpdOnline = False
              }
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
                    song =
                        Mpd.lookupPlaylist model.playlist status.songid

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
                        Html.a [ Attr.class "enabled", Events.onClick (sendCmd c) ] [ icon i "white" 42 ]

                    disbutton i =
                        Html.a [] [ icon i "#999" 42 ]

                    buttons =
                        div
                            [ Attr.class "buttons" ]
                        <|
                            case status.state of
                                "play" ->
                                    [ enbutton CmdPrevious icon_previous
                                    , enbutton CmdPause icon_pause
                                    , enbutton CmdStop icon_stop
                                    , enbutton CmdNext icon_next
                                    ]

                                "pause" ->
                                    [ enbutton CmdPrevious icon_previous
                                    , enbutton CmdPlay icon_play
                                    , enbutton CmdStop icon_stop
                                    , enbutton CmdNext icon_next
                                    ]

                                "stop" ->
                                    [ enbutton CmdPrevious icon_previous
                                    , enbutton CmdPlay icon_play
                                    , disbutton icon_stop
                                    , enbutton CmdNext icon_next
                                    ]

                                _ ->
                                    []

                    targetValueAsNumber : Json.Decoder Float
                    targetValueAsNumber =
                        Json.at [ "target", "valueAsNumber" ] Json.float

                    seek =
                        let
                            v =
                                case model.dragging of
                                    Dragging SliderSeek _ v ->
                                        v

                                    _ ->
                                        realElapsed
                        in
                        Html.input
                            [ Attr.type_ "range"
                            , Attr.min "0"
                            , Attr.max (toString status.duration)
                            , Events.on "input" (Json.map (StartDrag SliderSeek) targetValueAsNumber)
                            , Events.on "change" (Json.map (Seek status.songid) targetValueAsNumber)
                            , Attr.value (toString v)
                            ]
                            []

                    volume =
                        let
                            v =
                                case model.dragging of
                                    Dragging SliderVolume _ v ->
                                        v

                                    _ ->
                                        status.volume
                        in
                        div []
                            [ icon Solid.volume_down "white" 16
                            , Html.input
                                [ Attr.type_ "range"
                                , Attr.min "0"
                                , Attr.max "100"
                                , Events.on "input" (Json.map (StartDrag SliderVolume) targetValueAsNumber)
                                , Events.on "change" (Json.map SetVolume targetValueAsNumber)
                                , Attr.value (toString v)
                                ]
                                []
                            , icon Solid.volume_up "white" 16
                            ]
                in
                [ buttons
                ]
                    ++ (if status.state == "pause" || status.state == "play" then
                            [ div [ Attr.class "title" ] [ text song.title ]
                            , div [ Attr.class "artist" ] [ text song.artist ]
                            , div [ Attr.class "time" ]
                                [ seek
                                , Html.div [] [ text prettyTime ]
                                ]
                            ]

                        else
                            []
                       )
                    ++ [ volume
                       ]


viewHeader : Model -> Html Msg
viewHeader model =
    let
        count =
            " (" ++ (toString <| List.length model.playlist) ++ ")"

        tab what t title =
            Html.a
                [ Events.onClick <| Show what
                , Attr.class <|
                    "tab "
                        ++ (if model.view == what then
                                "current"

                            else
                                "inactive"
                           )
                , Attr.title title
                ]
                [ text t ]

        ( statusClick, cssClass, statusTitle, statusHover ) =
            let
                mpd =
                    case model.config of
                        Nothing ->
                            ""

                        Just c ->
                            " (host: " ++ c.mpdHost ++ ")"
            in
            case ( model.conn, model.mpdOnline ) of
                ( Nothing, _ ) ->
                    ( Connect, "offline", "Offline", "offline. Click to reconnect" )

                ( Just _, False ) ->
                    ( Show Playlist, "nompd", "No MPD", "connected to the Siren daemon, but no connection to MPD" ++ mpd )

                ( Just _, True ) ->
                    ( Show Playlist, "online", "Online", "connected to Siren and MPD" ++ mpd )
    in
    Html.nav []
        [ Html.a
            [ Attr.class "logo"
            , Events.onClick (Show Playlist)
            ]
            [ text "Siren!" ]
        , Html.span [] []
        , tab Playlist ("Playlist" ++ count) "Show playlist"
        , tab FileBrowser "Files" "Browse the filesystem"
        , case artistMode model.config of
            Artist ->
                tab (ArtistBrowser Artist) "Artists" "Browse by artist"

            Albumartist ->
                tab (ArtistBrowser Albumartist) "Artists" "Browse by albumartist"
        , Html.span [] []
        , Html.a
            [ Attr.class <| "status " ++ cssClass
            , Attr.title statusHover
            , Events.onClick statusClick
            ]
            [ text statusTitle ]
        ]


viewView : Model -> Html Msg
viewView model =
    case model.view of
        Playlist ->
            viewPlaylist model

        FileBrowser ->
            viewPanes model.fileView

        ArtistBrowser Artist ->
            viewPanes model.artistView

        ArtistBrowser Albumartist ->
            viewPanes model.albumartistView


viewPanes : List MPane -> Html Msg
viewPanes ps =
    div [ Attr.class "mc", Attr.id "mc" ] <|
        List.map (uncurry viewPane) (withCurrent ps)


withCurrent : List MPane -> List ( MPane, Maybe String )
withCurrent ps =
    let
        vp : List MPane -> List ( MPane, Maybe String )
        vp panes =
            case panes of
                [] ->
                    []

                p :: [] ->
                    [ ( p, Nothing ) ]

                p :: next :: rest ->
                    ( p, Just next.id ) :: vp (next :: rest)
    in
    vp ps


viewPane : MPane -> Maybe String -> Html Msg
viewPane p current =
    let
        viewEntry : Pane.Entry Msg -> Html Msg
        viewEntry e =
            div
                (List.filterMap identity
                    [ if current == Just e.id then
                        Just <| Attr.class "selected"

                      else
                        Nothing
                    , Maybe.map Events.onClick e.onClick
                    , case e.selection of
                        Nothing ->
                            Nothing

                        Just encodedCmd ->
                            Just <| Events.onDoubleClick <| replaceAndPlay encodedCmd
                    ]
                )
                [ text e.title ]

        viewBody : List (Pane.Entry Msg) -> List (Html Msg)
        viewBody es =
            List.map viewEntry es
    in
    case p.body of
        Pane.Entries es ->
            div [ Attr.class "pane" ]
                [ div [ Attr.class "title", Attr.title es.title ]
                    [ text es.title ]
                , div [ Attr.class "main" ] <|
                    case es.entries of
                        Nothing ->
                            [ div [] [ text "Loading..." ] ]

                        Just es_ ->
                            viewBody es_
                , div [ Attr.class "footer" ] <|
                    es.footer
                ]

        Pane.Info pb ->
            div [ Attr.class "endpane" ]
                [ div [ Attr.class "main" ] <|
                    case pb.body of
                        Nothing ->
                            [ text "Loading..." ]

                        Just b ->
                            b
                , div [ Attr.class "footer" ] <|
                    pb.footer
                ]



-- paneFooter sets footer for panes with entries


paneFooter : Pane.Body Msg -> Maybe String -> Pane.Body Msg
paneFooter p current =
    let
        sel : List (Pane.Entry Msg) -> List String
        sel es =
            List.filterMap .selection <|
                List.filter (\e -> current == Just e.id) es
    in
    case p of
        Pane.Info b ->
            Pane.Info b

        Pane.Entries b ->
            let
                footer =
                    case b.entries of
                        Nothing ->
                            [ text "" ]

                        Just es ->
                            case sel es of
                                [] ->
                                    [ text "" ]

                                encodedCmd :: _ ->
                                    [ Html.button
                                        [ Events.onClick <| SendWS encodedCmd
                                        , Attr.class "add"
                                        ]
                                        [ text "ADD TO PLAYLIST" ]
                                    , Html.button
                                        [ Events.onClick <| replaceAndPlay encodedCmd
                                        , Attr.class "play"
                                        ]
                                        [ text "PLAY" ]
                                    ]
            in
            Pane.Entries { b | footer = footer }


viewPlaylist : Model -> Html Msg
viewPlaylist model =
    let
        col cl txt =
            div [ Attr.class cl ] [ txt ]
    in
    div [ Attr.class "playlistwrap" ]
        [ div [ Attr.class "playlist" ]
            [ div [ Attr.class "commands" ]
                [ button [ Events.onClick <| sendCmd <| CmdClear ] [ text "CLEAR PLAYLIST" ]
                ]
            , div [ Attr.class "header" ]
                [ col "track" <| text "Track"
                , col "title" <| text "Title"
                , col "artist" <| text "Artist"
                , col "album" <| text "Album"
                , col "dur" <| text ""
                ]
            ]
        , div [ Attr.class "entries" ]
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

                        track =
                            if current && Maybe.map .state model.status == Just "play" then
                                icon icon_play "white" 16

                            else if current && Maybe.map .state model.status == Just "pause" then
                                icon icon_pause "white" 16

                            else
                                text t.track
                    in
                    div
                        [ Attr.class
                            (if current then
                                "entry playing"

                             else
                                "entry "
                            )
                        , Events.onDoubleClick <| sendCmd <| CmdPlayID e.id
                        ]
                        [ col "track" track
                        , col "title" <| text t.title
                        , col "artist" <|
                            text <|
                                case artistMode model.config of
                                    Artist ->
                                        t.artist

                                    Albumartist ->
                                        if t.albumartist == "" then
                                            t.artist

                                        else
                                            t.albumartist
                        , col "album" <| text t.album
                        , col "dur" <| text <| prettySecs t.duration
                        ]
                )
                model.playlist
            )
        , viewPlayer model
        ]


subscriptions : Model -> Sub Msg
subscriptions model =
    case ( model.conn, model.mpdOnline ) of
        ( Just _, True ) ->
            Time.every Time.second Tick

        _ ->
            Sub.none


wsSend : Maybe Explicit.WebSocket -> String -> Cmd Msg
wsSend mconn o =
    case mconn of
        Nothing ->
            Debug.log "sending without connection" Cmd.none

        Just conn ->
            Explicit.send conn o (\err -> Debug.log ("msg err: " ++ err) Noop)


sendCmd : WSCmd -> Msg
sendCmd cmd =
    SendWS <| Mpd.encodeCmd <| cmd


replaceAndPlay : String -> Msg
replaceAndPlay encodedAddCmd =
    SendWS <|
        Mpd.encodeCmd CmdClear
            ++ encodedAddCmd
            ++ Mpd.encodeCmd CmdPlay


setFilePane : String -> List Mpd.Inode -> List MPane -> List MPane
setFilePane paneid inodes panes =
    let
        es =
            toFilePaneEntries paneid inodes
    in
    Pane.update
        (\b ->
            case b of
                Pane.Info i ->
                    Pane.Info i

                Pane.Entries e ->
                    Pane.Entries { e | entries = Just es }
        )
        paneid
        panes


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
                                Pane.new pid (Pane.loading title) (Mpd.encodeCmd <| CmdLoadDir pid id)
                        )
                        (Just <| Mpd.encodeCmd <| CmdPlaylistAdd id)

                Mpd.File id name ->
                    let
                        pid =
                            "dir" ++ id
                    in
                    Pane.Entry pid
                        name
                        (Just <| AddFilePane paneid (filePane pid id name))
                        (Just <| Mpd.encodeCmd <| CmdPlaylistAdd id)
    in
    List.map entry inodes


setListPane : String -> ArtistMode -> List Mpd.DBEntry -> List MPane -> List MPane
setListPane paneid mode db panes =
    let
        es =
            toListPaneEntries paneid mode db
    in
    Pane.update
        (\b ->
            case b of
                Pane.Info i ->
                    Pane.Info i

                Pane.Entries e ->
                    Pane.Entries { e | entries = Just es }
        )
        paneid
        panes


toListPaneEntries : String -> ArtistMode -> List Mpd.DBEntry -> List (Pane.Entry Msg)
toListPaneEntries parentid mode ls =
    let
        entry e =
            case e of
                Mpd.DBArtist artist ->
                    let
                        id =
                            "artist" ++ artist

                        add =
                            Mpd.encodeCmd <| CmdFindAdd mode { artist = artist, album = "", track = "" }
                    in
                    Pane.Entry id
                        artist
                        (Just <|
                            AddArtistPane
                                mode
                                parentid
                                (Pane.new id (Pane.loading artist) (Mpd.encodeCmd <| CmdList id mode { what = "artistalbums", artist = artist, album = "" }))
                        )
                        (Just add)

                Mpd.DBAlbum artist album ->
                    let
                        id =
                            "album" ++ artist ++ album

                        add =
                            Mpd.encodeCmd <| CmdFindAdd mode { artist = artist, album = album, track = "" }
                    in
                    Pane.Entry id
                        album
                        (Just <|
                            AddArtistPane
                                mode
                                parentid
                                (Pane.new id (Pane.loading album) (Mpd.encodeCmd <| CmdList id mode { what = "araltracks", artist = artist, album = album }))
                        )
                        (Just add)

                Mpd.DBTrack t ->
                    let
                        pid =
                            "track" ++ t.id

                        -- TODO: use "add file" ?
                        add =
                            Mpd.encodeCmd <| CmdFindAdd mode { artist = t.artist, album = t.album, track = t.title }
                    in
                    Pane.Entry pid
                        (t.track ++ " " ++ t.title)
                        (Just <|
                            AddArtistPane
                                mode
                                parentid
                                (filePane pid t.id t.title)
                        )
                        (Just add)
    in
    List.map entry ls


setTrackPane : String -> Mpd.Track -> List MPane -> List MPane
setTrackPane paneid track panes =
    let
        body =
            toPane track
    in
    Pane.update
        (\b ->
            case b of
                Pane.Info i ->
                    Pane.Info { i | body = Just body }

                Pane.Entries e ->
                    Pane.Entries e
        )
        paneid
        panes


reloadViews : Model -> Cmd Msg
reloadViews m =
    Cmd.batch <|
        List.map (\p -> wsSend m.conn p.update) (m.fileView ++ m.artistView ++ m.albumartistView)


scrollNC : Cmd Msg
scrollNC =
    Task.attempt (\_ -> Noop) <| Scroll.toRight "mc"


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
        pbody =
            Pane.Info
                { body = Nothing
                , footer =
                    [ button
                        [ Events.onClick <|
                            replaceAndPlay <|
                                Mpd.encodeCmd (CmdPlaylistAdd fileid)
                        ]
                        [ text "PLAY" ]
                    ]
                }
    in
    Pane.new paneid pbody (Mpd.encodeCmd <| CmdTrack paneid fileid)


toPane : Mpd.Track -> List (Html Msg)
toPane t =
    [ icon Solid.music "#000" 12
    , text <| " " ++ t.title
    , Html.br [] []
    , text <| "artist: " ++ t.artist
    , Html.br [] []
    , text <| "album artist: " ++ t.albumartist
    , Html.br [] []
    , text <| "album: " ++ t.album
    , Html.br [] []
    , text <| "track: " ++ t.track
    , Html.br [] []
    , text <| "duration: " ++ prettySecs t.duration
    , Html.br [] []
    ]


icon : Html Msg -> String -> Int -> Html Msg
icon i c width =
    Html.div
        [ Attr.style
            [ ( "width", toString width ++ "px" )
            , ( "color", c )
            , ( "display", "inline-block" )
            ]
        ]
        [ i ]


artistMode : Maybe Mpd.Config -> ArtistMode
artistMode mc =
    case mc of
        Nothing ->
            Albumartist

        Just c ->
            c.artistMode
