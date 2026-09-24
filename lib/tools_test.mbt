///|
/// The programs whose effect is decided by a flag or a subcommand: find,
/// sqlite3, make, the container runtimes, and the package managers.
///
/// The facts asserted here were measured in a scratch directory: `make -C sub`
/// leaves its output inside `sub`, `sqlite3 new.db 'select 1'` creates the
/// database file, `npm install` rewrites the lockfile, and `find -delete`
/// removes matching entries under the directories it was given. The cases that
/// need a daemon or a registry (docker's mounts, the package indexes) are
/// marked uncertain on purpose: the path is known, the fact that something
/// remote is consulted is a hole.
test "find reads what it walks and deletes a set decided by its expression" {
  // Which entries match is the expression's business, so the delete is dynamic.
  inspect(touched("find . -name '*.tmp' -delete"), content="R:. D:.")
  inspect(touched("find sub -name '*.tmp' -delete"), content="R:sub D:sub")
  // Without -delete there is nothing to remove.
  inspect(touched("find . -name '*.tmp'"), content="R:.")
  // A plain walk with no start point still reads the working directory.
  inspect(touched("find -name '*.tmp'"), content="R:.")
  // -exec runs a command that is right there in the arguments, with `{}` as
  // the hole standing for each match.
  inspect(touched("find sub -exec rm -rf {} ;"), content="R:sub D:{} U:{}")
  inspect(
    @lib.analyze("find . -name '*.tmp' -delete").impact.uncertain,
    content="true",
  )
}

///|
test "sqlite3 opens the database file, and may well create it" {
  // Measured: `sqlite3 new.db 'select 1'` leaves a zero-length new.db behind,
  // so the write is real even for a query. Whether a statement modifies an
  // existing database cannot be settled from the text, hence dynamic.
  inspect(touched("sqlite3 t.db 'select 1'"), content="R:t.db W:t.db")
  inspect(
    touched("sqlite3 t.db 'insert into x values (1)'"),
    content="R:t.db W:t.db",
  )
  inspect(
    @lib.analyze("sqlite3 t.db 'select 1'").impact.uncertain,
    content="true",
  )
  // No file argument means an in-memory database: nothing to report.
  inspect(touched("sqlite3"), content="")
}

///|
test "make reports the directory it builds in" {
  // Measured: `make -C sub` creates its output inside sub.
  inspect(touched("make -C sub"), content="R:sub W:sub")
  inspect(touched("make -f other.mk"), content="R:. R:other.mk W:.")
  // The build output is decided by rules the tool does not read.
  inspect(@lib.analyze("make -C sub").impact.uncertain, content="true")
}

///|
test "a container mount hands over the host path" {
  inspect(
    touched("docker run -v /host/data:/data img"),
    content="W:/host/data N:container registry",
  )
  // A read-only mount says so, and then there is nothing to write.
  inspect(
    touched("docker run -v /host/data:/data:ro img"),
    content="R:/host/data N:container registry",
  )
  inspect(
    touched("docker run --mount type=bind,source=/srv/x,target=/x img"),
    content="W:/srv/x N:container registry",
  )
  // The build context is the last argument, not the subcommand.
  inspect(touched("docker build -t x ."), content="R:. N:container registry")
  // An unmodelled subcommand stays unmodelled.
  debug_inspect(
    @lib.analyze("docker compose up").impact.effects[0].modeled,
    content="false",
  )
}

///|
test "package managers read what they can and say the rest is a hole" {
  inspect(
    touched("npm install"),
    content="R:package.json W:package-lock.json W:node_modules N:package registry",
  )
  // `npm ci` throws the installed tree away first.
  inspect(
    touched("npm ci"),
    content="R:package.json D:node_modules W:node_modules N:package registry",
  )
  // A requirement file is a path the command line names.
  inspect(
    touched("pip install -r req.txt"),
    content="R:req.txt U:python environment N:package index",
  )
  inspect(
    touched("uv pip install ./dist/x.whl"),
    content="R:./dist/x.whl U:python environment N:package index",
  )
}
