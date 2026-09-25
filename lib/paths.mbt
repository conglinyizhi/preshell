///|
/// Path shapes. These are facts about text, not policy: nothing here decides
/// whether a path is acceptable, only what it is.
///
/// The auditor has no allowlist and no roots to compare against; "is this path
/// allowed" belongs to the caller. What it must get right is *which* path the
/// command would touch.
///
/// Resolution stops here on purpose: symlinks, globs, `~` and the current
/// directory are the caller's to resolve, and `Impact.uncertain` says when that
/// matters.
pub fn normalize_path(p : String) -> String {
  let absolute = p.has_prefix("/")
  let out : Array[String] = []
  for seg in p.split("/") {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      let top = if out.length() > 0 { out[out.length() - 1] } else { "" }
      if out.length() > 0 && top != ".." {
        ignore(out.pop())
      } else if !absolute {
        // Two `..` in a row are two levels up, and a relative path may climb
        // above where it started. Letting the second one pop the first
        // collapsed `cd ../..` into a single level and reported the wrong
        // directory.
        out.push("..")
      }
      // An absolute path cannot climb above the root: `/..` is `/`.
      continue
    }
    out.push(seg.to_owned())
  }
  let body = out.join("/")
  if absolute {
    "/" + body
  } else {
    body
  }
}

///|
/// The directory a path lives in, normalized. `build/out.o` -> `build`,
/// `a/b/` -> `a`, `x` -> `.`
pub fn parent_dir(p : String) -> String {
  let norm = normalize_path(p)
  if p.has_suffix("/") {
    if norm == "" {
      "/"
    } else {
      norm
    }
  } else {
    match norm.rev_find("/") {
      Some(0) => "/"
      Some(i) => norm.unsafe_substring(start=0, end=i)
      None => "."
    }
  }
}
