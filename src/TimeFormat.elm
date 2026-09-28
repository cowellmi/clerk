module TimeFormat exposing (date, sortableUtc)

import Time


{-| Format a timestamp as `YYYY-MM-DD` in the given time zone.
-}
date : Time.Zone -> Time.Posix -> String
date zone posix =
    String.fromInt (Time.toYear zone posix)
        ++ "-"
        ++ monthToString (Time.toMonth zone posix)
        ++ "-"
        ++ String.padLeft 2 '0' (String.fromInt (Time.toDay zone posix))


{-| `YYYY-MM-DDTHH-MM-SS` in UTC: sorts chronologically as text and is safe in
file names (no colons). Used in saved recipe ids.
-}
sortableUtc : Time.Posix -> String
sortableUtc posix =
    date Time.utc posix
        ++ "T"
        ++ twoDigits (Time.toHour Time.utc posix)
        ++ "-"
        ++ twoDigits (Time.toMinute Time.utc posix)
        ++ "-"
        ++ twoDigits (Time.toSecond Time.utc posix)


monthToString : Time.Month -> String
monthToString month =
    case month of
        Time.Jan ->
            "01"

        Time.Feb ->
            "02"

        Time.Mar ->
            "03"

        Time.Apr ->
            "04"

        Time.May ->
            "05"

        Time.Jun ->
            "06"

        Time.Jul ->
            "07"

        Time.Aug ->
            "08"

        Time.Sep ->
            "09"

        Time.Oct ->
            "10"

        Time.Nov ->
            "11"

        Time.Dec ->
            "12"


twoDigits : Int -> String
twoDigits n =
    String.padLeft 2 '0' (String.fromInt n)
