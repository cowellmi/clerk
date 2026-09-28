module Icons exposing (arrowUp, eraser, gitFork, pencil, plus, save, trash, undo, x)

-- icons from Lucide (https://lucide.dev, ISC license).

import Html exposing (Html)
import Html.Attributes as HA
import Svg exposing (circle, path, svg)
import Svg.Attributes as SA


arrowUp : Html msg
arrowUp =
    icon
        [ path [ SA.d "m5 12 7-7 7 7" ] []
        , path [ SA.d "M12 19V5" ] []
        ]


eraser : Html msg
eraser =
    icon
        [ path [ SA.d "M21 21H8a2 2 0 0 1-1.42-.587l-3.994-3.999a2 2 0 0 1 0-2.828l10-10a2 2 0 0 1 2.829 0l5.999 6a2 2 0 0 1 0 2.828L12.834 21" ] []
        , path [ SA.d "m5.082 11.09 8.828 8.828" ] []
        ]


gitFork : Html msg
gitFork =
    icon
        [ circle [ SA.cx "12", SA.cy "18", SA.r "3" ] []
        , circle [ SA.cx "6", SA.cy "6", SA.r "3" ] []
        , circle [ SA.cx "18", SA.cy "6", SA.r "3" ] []
        , path [ SA.d "M18 9v2c0 .6-.4 1-1 1H7c-.6 0-1-.4-1-1V9" ] []
        , path [ SA.d "M12 12v3" ] []
        ]


pencil : Html msg
pencil =
    icon
        [ path [ SA.d "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z" ] []
        , path [ SA.d "m15 5 4 4" ] []
        ]


plus : Html msg
plus =
    icon
        [ path [ SA.d "M5 12h14" ] []
        , path [ SA.d "M12 5v14" ] []
        ]


save : Html msg
save =
    icon
        [ path [ SA.d "M15.2 3a2 2 0 0 1 1.4.6l3.8 3.8a2 2 0 0 1 .6 1.4V19a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" ] []
        , path [ SA.d "M17 21v-7a1 1 0 0 0-1-1H8a1 1 0 0 0-1 1v7" ] []
        , path [ SA.d "M7 3v4a1 1 0 0 0 1 1h7" ] []
        ]


trash : Html msg
trash =
    icon
        [ path [ SA.d "M10 11v6" ] []
        , path [ SA.d "M14 11v6" ] []
        , path [ SA.d "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" ] []
        , path [ SA.d "M3 6h18" ] []
        , path [ SA.d "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" ] []
        ]


{-| Lucide's `undo-2`. -}
undo : Html msg
undo =
    icon
        [ path [ SA.d "M9 14 4 9l5-5" ] []
        , path [ SA.d "M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11" ] []
        ]


x : Html msg
x =
    icon
        [ path [ SA.d "M18 6 6 18" ] []
        , path [ SA.d "m6 6 12 12" ] []
        ]


icon : List (Svg.Svg msg) -> Html msg
icon children =
    svg
        [ SA.viewBox "0 0 24 24"
        , SA.width "1em"
        , SA.height "1em"
        , SA.fill "none"
        , SA.stroke "currentColor"
        , SA.strokeWidth "2"
        , SA.strokeLinecap "round"
        , SA.strokeLinejoin "round"
        , SA.class "icon"
        , HA.attribute "aria-hidden" "true"
        ]
        children
