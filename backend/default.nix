{mkDerivation, loch-th, groundhog, groundhog-th, mtl, focus-core, focus-serve, lens, aeson, snap, resource-pool, text, network, stm, postgresql-simple, groundhog-postgresql, websockets-snap, websockets, stripe, smtp-mail, temporary, stringsearch, shelly, tar, file-embed, binary, lucid, diagrams, diagrams-lib, diagrams-svg, raw-strings-qq, attoparsec, focus-th, mustache, parsec, vector, myPostgres}:

mkDerivation {
  pname = "focus-backend";
  license = null;
  version = "0.1";
  src = ./.;
  buildDepends = [
    groundhog
    groundhog-th
    mtl
    focus-core
    focus-th
    focus-serve
    lens
    aeson
    snap
    resource-pool
    text
    network
    stm
    postgresql-simple
    groundhog-postgresql
    websockets-snap
    websockets
    stripe
    smtp-mail
    temporary
    stringsearch
    shelly
    tar
    file-embed
    binary
    lucid
    diagrams
    diagrams-lib
    diagrams-svg
    raw-strings-qq
    attoparsec
    loch-th
    mustache
    parsec
    vector
  ];
  pkgconfigDepends = [
    myPostgres
  ];
}
