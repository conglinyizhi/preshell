///|
/// The container runtimes: `docker`, `podman` and the rest, and the mounts
/// their arguments declare.
///
/// A mount is the interesting part. Everything else about a container run is a
/// name, while `-v HOST:CONTAINER` says which host directory is reachable and
/// whether it is writable — so the read/write split is decided here, and a mount
/// this parser cannot read becomes a hole rather than a guess. Whether the image
/// is pulled depends on a local cache, so that contact stays a hole too.

///|
/// Containers: a bind mount hands the host path to the container, which may
/// write it; `:ro` says it will not. The image name is not a path, and whether
/// it is pulled depends on the local cache, so the network contact is a hole.
fn Collector::container_effects(
  self : Collector,
  name : String,
  s : SimpleCmd,
  line : Int,
) -> Unit {
  let words = s.words
  // The subcommand decides everything: `run` mounts host paths, `build` reads a
  // build context, `pull` only leaves the machine.
  let mut sub = ""
  let mut sub_at = 0
  let mut i = 1
  for ;; {
    if i >= words.length() {
      break
    }
    let t = words[i].literal_text()
    if t == "" || t.has_prefix("-") {
      i += 1
    } else {
      sub = t
      sub_at = i
      break
    }
  }
  match sub {
    "run" | "create" => {
      self.push(Exec, name, false, line)
      // The image is the first word that is not one of docker's own options, and
      // it is what the container starts: `docker run --rm node -e 'x'` starts
      // node, which is what makes the words after it legible to a caller (issue
      // #5). The value of an option is skipped the same way the runners skip
      // theirs, so `-v /host:/c node` names node.
      let mut j = sub_at + 1
      let image_opts = runner_value_opts("docker")
      while j < words.length() {
        let t = words[j].literal_text()
        if t == "" {
          j += 1
          continue
        }
        if t.has_prefix("-") {
          j += 1 + wrapper_option_extra_words(image_opts, t)
          continue
        }
        self.push(
          Spawn,
          t,
          true,
          line,
          payload=self.payload_for(t, words[j + 1:], s.redirects),
        )
        break
      }
      let mut k = 1
      for ;; {
        if k >= words.length() {
          break
        }
        let t = words[k].literal_text()
        if t == "-v" || t == "--volume" {
          if k + 1 < words.length() {
            self.mount_effects(words[k + 1].literal_text(), false, line)
          }
          k += 2
        } else if t.has_prefix("--volume=") {
          self.mount_effects(
            t.unsafe_substring(start=9, end=t.length()),
            false,
            line,
          )
          k += 1
        } else if t == "--mount" {
          if k + 1 < words.length() {
            self.mount_effects(words[k + 1].literal_text(), true, line)
          }
          k += 2
        } else if t.has_prefix("--mount=") {
          self.mount_effects(
            t.unsafe_substring(start=8, end=t.length()),
            true,
            line,
          )
          k += 1
        } else if t == "--volumes-from" {
          // The mounts come from another container, which static analysis does
          // not follow.
          self.push(Unknown, t, true, line)
          k += 2
        } else {
          k += 1
        }
      }
      // The image may have to be fetched; the local cache decides, so the
      // registry is a hole rather than a named host.
      self.push(Net, "container registry", true, line)
    }
    "build" | "buildx" => {
      // The build context is the last non-option argument, and the subcommand
      // word itself is not it: `docker build -t x .` reads `.`.
      self.push(Exec, name, false, line)
      let mut ctx = ""
      let mut k = 2
      for ;; {
        if k >= words.length() {
          break
        }
        let t = words[k].literal_text()
        if t != "" && !t.has_prefix("-") {
          ctx = t
        }
        k += 1
      }
      if ctx == "" {
        ctx = "."
      }
      self.push(Read, ctx, true, line)
      self.push(Net, "container registry", true, line)
    }
    "pull" | "push" | "login" | "search" => {
      self.push(Exec, name, false, line)
      self.push(Net, "container registry", true, line)
    }
    _ =>
      // Anything else: say the tool does not model it instead of guessing.
      self.push(Exec, name, false, line, modeled=false)
  }
}

///|
/// The first word that is not an option, from `start` on.

///|
/// One mount specification: `HOST:CONTAINER[:ro]`, or the `--mount` spelling
/// `type=bind,source=HOST,target=CONTAINER`.
fn Collector::mount_effects(
  self : Collector,
  spec : String,
  keyed : Bool,
  line : Int,
) -> Unit {
  let mut host = ""
  let mut read_only = false
  if keyed {
    for part in spec.split(",").to_array() {
      let p = part.trim().to_owned()
      if p.has_prefix("source=") {
        host = p.unsafe_substring(start=7, end=p.length())
      } else if p.has_prefix("src=") {
        host = p.unsafe_substring(start=4, end=p.length())
      } else if p == "readonly" || p == "ro" {
        read_only = true
      }
    }
  } else {
    let parts = spec.split(":").to_array()
    if parts.length() > 0 {
      host = parts[0].trim().to_owned()
    }
    if parts.length() > 2 && parts[2].trim() == "ro" {
      read_only = true
    }
  }
  if host == "" {
    return
  }
  if read_only {
    self.push(Read, host, false, line)
  } else {
    // The container decides how much it writes, so the target is a hole.
    self.push(Write, host, true, line)
  }
}
