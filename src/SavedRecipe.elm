module SavedRecipe exposing (ForkOrigin, SavedRecipe, encode, encodeForkOrigin, encodeList, forkOrigin, forkOriginDecoder, listDecoder, new, slug)

{-| A recipe the user saved, as stored in localStorage (`clerk.recipes`).
-}

import Json.Decode as D
import Json.Encode as E
import Recipe exposing (Recipe)
import Time
import TimeFormat


type alias SavedRecipe =
    { id : String -- "{datetime}-{slug(title)}", e.g. "2026-09-16T14-05-33-chicken-and-rice-bowl"
    , recipe : Recipe
    , createdAt : Time.Posix
    , updatedAt : Time.Posix
    , forkedFrom : Maybe ForkOrigin
    }


{-| A snapshot of the recipe this one was forked from, not a reference: the
original may since have been deleted.
-}
type alias ForkOrigin =
    { id : String
    , title : String
    }


{-| A newly saved recipe, and what it was forked from, if anything.
-}
new : Time.Posix -> Maybe ForkOrigin -> Recipe -> SavedRecipe
new now forkedFrom recipe =
    { id = TimeFormat.sortableUtc now ++ "-" ++ slug recipe.title
    , recipe = recipe
    , createdAt = now
    , updatedAt = now
    , forkedFrom = forkedFrom
    }


{-| The origin a fork of this recipe records: its id and current title.
-}
forkOrigin : SavedRecipe -> ForkOrigin
forkOrigin saved =
    { id = saved.id, title = saved.recipe.title }


{-| Lowercase, with each run of characters other than a-z and 0-9 collapsed to
one `-`, and no `-` at either end. An empty result becomes `untitled`.
-}
slug : String -> String
slug title =
    let
        dashed =
            title
                |> String.toLower
                |> String.toList
                |> List.foldr
                    (\c acc ->
                        if Char.isAlphaNum c then
                            c :: acc

                        else if List.head acc == Just '-' then
                            acc

                        else
                            '-' :: acc
                    )
                    []
                |> String.fromList
                |> trimDashes
    in
    if String.isEmpty dashed then
        "untitled"

    else
        dashed


trimDashes : String -> String
trimDashes str =
    if String.startsWith "-" str then
        trimDashes (String.dropLeft 1 str)

    else if String.endsWith "-" str then
        trimDashes (String.dropRight 1 str)

    else
        str



-- JSON


{-| Lenient: a recipe that doesn't decode is dropped rather than losing the
whole list.
-}
listDecoder : D.Decoder (List SavedRecipe)
listDecoder =
    D.list (D.maybe decoder)
        |> D.map (List.filterMap identity)


{-| Flat, one object per recipe: `id`, `title`, `ingredients`, `steps`,
`createdAt` and `updatedAt` (Unix milliseconds), and `forkedFrom`
(`{ id, title }` or `null`). The same shape as a Connected-mode recipe file.
-}
encodeList : List SavedRecipe -> E.Value
encodeList =
    E.list encode


decoder : D.Decoder SavedRecipe
decoder =
    D.map5 SavedRecipe
        (D.field "id" D.string)
        Recipe.decoder
        (D.field "createdAt" (D.map Time.millisToPosix D.int))
        (D.field "updatedAt" (D.map Time.millisToPosix D.int))
        (D.field "forkedFrom" (D.nullable forkOriginDecoder))


{-| `{ id, title }`.
-}
forkOriginDecoder : D.Decoder ForkOrigin
forkOriginDecoder =
    D.map2 ForkOrigin
        (D.field "id" D.string)
        (D.field "title" D.string)


encodeForkOrigin : ForkOrigin -> E.Value
encodeForkOrigin origin =
    E.object
        [ ( "id", E.string origin.id )
        , ( "title", E.string origin.title )
        ]


encode : SavedRecipe -> E.Value
encode saved =
    E.object
        (( "id", E.string saved.id )
            :: Recipe.encodeFields saved.recipe
            ++ [ ( "createdAt", E.int (Time.posixToMillis saved.createdAt) )
               , ( "updatedAt", E.int (Time.posixToMillis saved.updatedAt) )
               , ( "forkedFrom"
                 , case saved.forkedFrom of
                    Just origin ->
                        encodeForkOrigin origin

                    Nothing ->
                        E.null
                 )
               ]
        )
