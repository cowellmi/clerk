module Route exposing (Route(..), fromUrl, toFragment)

import Url exposing (Url)
import Url.Parser as Parser exposing ((</>), Parser, oneOf, s)


type Route
    = Create
    | Stock
    | Saved
    | Recipe String
    | Settings
    | NotFound


fromUrl : Url -> Route
fromUrl url =
    { url | path = Maybe.withDefault "" url.fragment, fragment = Nothing }
        |> Parser.parse parser
        |> Maybe.withDefault NotFound


toFragment : Route -> String
toFragment route =
    case route of
        Create ->
            "#/create"

        Stock ->
            "#/stock"

        Saved ->
            "#/saved"

        Recipe id ->
            "#/recipe/" ++ id

        Settings ->
            "#/settings"

        NotFound ->
            "#/create"


parser : Parser (Route -> a) a
parser =
    oneOf
        [ Parser.map Create (s "create")
        , Parser.map Stock (s "stock")
        , Parser.map Saved (s "saved")
        , Parser.map Recipe (s "recipe" </> Parser.string)
        , Parser.map Settings (s "settings")
        ]
