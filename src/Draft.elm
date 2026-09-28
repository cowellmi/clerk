module Draft exposing (Draft, commit, edit, init, isDirty, set)

{-| A value being edited alongside the last saved version of it.

`saved` is what's in storage and what the rest of the app should read.
`draft` is what the form is editing. Saving is enabled while they differ.

-}


type alias Draft a =
    { saved : a
    , draft : a
    }


init : a -> Draft a
init value =
    { saved = value, draft = value }


set : a -> Draft a -> Draft a
set value d =
    { d | draft = value }


edit : (a -> a) -> Draft a -> Draft a
edit f d =
    { d | draft = f d.draft }


isDirty : Draft a -> Bool
isDirty d =
    d.draft /= d.saved


commit : Draft a -> Draft a
commit d =
    { d | saved = d.draft }
