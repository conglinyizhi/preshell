///|
/// What each program does, one function per family.
///
/// classify.mbt decides *which* family a command word belongs to and calls it;
/// the behaviour itself lives here. The split matters because these functions
/// are where the claims are: `cp -t dir a` writes `dir/a`, `sed -i.bak` writes
/// the file and its backup, `mv` deletes what it moves. Every one of them was
/// measured against the real program, and the notes say what was run.
///
/// A program with no function here is not thereby harmless. classify.mbt reports
/// it as unmodelled, and from that point the effect list is a lower bound — the
/// one thing a caller must not read as "touches nothing".
///
/// Two shapes recur and are worth naming once. A command that *reads* its
/// operands and one that *writes* them differ only in the push; a command that
/// takes a directory (`-t`, `-d`) joins the operand onto it rather than
/// replacing it, and the directory's own hole makes the result dynamic.

///|
/// Every path in the list is written at this line.
fn Collector::write_paths(
  self : Collector,
  xs : Array[PathArg],
  line : Int,
) -> Unit {
  for it in xs {
    self.push_path(Write, it, line)
  }
}

///|
/// Every path in the list is read at this line.
fn Collector::read_paths(
  self : Collector,
  xs : Array[PathArg],
  line : Int,
) -> Unit {
  for it in xs {
    self.push_path(Read, it, line)
  }
}

///|
/// `rm a b c` deletes every operand it names. What a recursive `-r` walks at run
/// time is not in the command line, but the paths that are named are named.
fn Collector::delete_operand_effects(
  self : Collector,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  for it in operands {
    self.push_path(Delete, it, line)
  }
}

///|
/// The readers: text filters and inspectors whose every operand is a file they
/// open. `source` and `.` are here because running a script reads it.
fn Collector::read_operand_effects(
  self : Collector,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  self.read_paths(operands, line)
}

///|
/// `tee`, `touch`, `truncate` and `mkdir` create or modify what they are given.
fn Collector::write_operand_effects(
  self : Collector,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  self.write_paths(operands, line)
}

///|
/// `find` reads the directories it starts from. Its predicates are not paths:
/// reporting `-name`'s argument as a file is the kind of invented fact that
/// makes a report untrustworthy, so only the starting points count.
fn Collector::find_operand_effects(
  self : Collector,
  items : Array[PathArg],
  line : Int,
) -> Unit {
  self.read_paths(leading_operands(items), line)
}

///|
/// `grep`/`rg`/`awk`/`sed`: the first operand is a pattern or a script, not a
/// path, unless the pattern came from an option (`-f`, `-e`) — then every
/// operand is a file.
///
/// `sed -i` is the exception that writes: it edits in place, and with a suffix
/// (`-i.bak`) it leaves the backup behind too. The suffix has to be attached; a
/// bare `-i` makes no backup.
fn Collector::script_effects(
  self : Collector,
  n : String,
  scan : ArgScan,
  script_operands : Array[PathArg],
  line : Int,
) -> Unit {
  let in_place = n == "sed" &&
    (scan.opts.contains("-i") || scan.opts.contains("--in-place"))
  if in_place {
    self.write_paths(script_operands, line)
    match value_of(scan, ["-i", "--in-place"]) {
      Some(suffix) =>
        for it in script_operands {
          self.push_path(Write, it.plus_suffix(suffix), line)
        }
      None => ()
    }
  } else {
    self.read_paths(script_operands, line)
  }
}

///|
/// `chmod`/`chown`/`chgrp`: the first operand is the mode, the owner or the
/// group, and the rest are files. With `--reference` the value comes from an
/// option, so every operand is a file. Reporting `644` as a written path is the
/// kind of invented fact that makes a report untrustworthy.
fn Collector::mode_effects(
  self : Collector,
  operands : Array[PathArg],
  scan : ArgScan,
  line : Int,
) -> Unit {
  let files = if scan.opts.contains("--reference") {
    operands
  } else if operands.length() > 1 {
    operands[1:].to_owned()
  } else {
    []
  }
  self.write_paths(files, line)
}

///|
/// `ln`: with `-t dir` the link is created inside the directory, under the
/// operand's own name, and the directory's hole makes the link dynamic. Without
/// it, the last operand is what gets created and the rest are read.
fn Collector::link_effects(
  self : Collector,
  operands : Array[PathArg],
  scan : ArgScan,
  line : Int,
) -> Unit {
  match scan.target_dir {
    Some(dir) =>
      for it in operands {
        self.push_path(Read, it, line)
        self.push_path(Write, it.in_dir(dir), line)
      }
    None =>
      if operands.length() > 0 {
        let n_op = operands.length()
        for i, it in operands {
          if i == n_op - 1 {
            self.push_path(Write, it, line)
          } else {
            self.push_path(Read, it, line)
          }
        }
      }
  }
}

///|
/// `split`/`csplit` read their input and name their outputs themselves (xaa,
/// xab, ...), which is not something the command line says.
fn Collector::split_effects(
  self : Collector,
  n : String,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  self.read_paths(operands, line)
  if operands.length() > 0 {
    self.push(Unknown, n + ": output file names are derived", true, line)
  }
}

///|
/// `cp`/`mv`/`install`/`rsync`: the last operand is written and the rest are
/// read — except for `mv`, which removes the sources rather than reading them
/// (measured: `D:a.txt W:destdir/a.txt`). With `-t dir` every operand lands
/// inside the directory instead, and the directory's own hole makes the write
/// dynamic.
fn Collector::copy_effects(
  self : Collector,
  n : String,
  operands : Array[PathArg],
  scan : ArgScan,
  line : Int,
) -> Unit {
  match scan.target_dir {
    Some(dir) =>
      for it in operands {
        if n == "mv" {
          self.push_path(Delete, it, line)
        } else {
          self.push_path(Read, it, line)
        }
        self.push_path(Write, it.in_dir(dir), line)
      }
    None => {
      let n_op = operands.length()
      for i, it in operands {
        if i == n_op - 1 {
          self.push_path(Write, it, line)
        } else {
          self.push_path(Read, it, line)
        }
      }
    }
  }
}

///|
/// `zip archive.zip members...`: the archive is written, the members read.
fn Collector::zip_effects(
  self : Collector,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  match operands {
    [head, .. rest] => {
      self.push_path(Write, head, line)
      for it in rest {
        self.push_path(Read, it, line)
      }
    }
    [] => ()
  }
}

///|
/// `dd` names its files as `if=`/`of=` operands rather than as positional
/// arguments, and the value is a path like any other: `of=$HOME/x` stays a hole.
fn Collector::dd_effects(
  self : Collector,
  items : Array[PathArg],
  line : Int,
) -> Unit {
  for it in items {
    let t = it.text
    if t.has_prefix("of=") {
      let value = t.unsafe_substring(start=3, end=t.length())
      self.push(
        Write,
        value,
        it.dynamic,
        line,
        unrooted=value_head_unresolved(value, it.dynamic),
        vars=it.vars,
      )
    }
    if t.has_prefix("if=") {
      let value = t.unsafe_substring(start=3, end=t.length())
      self.push(
        Read,
        value,
        it.dynamic,
        line,
        unrooted=value_head_unresolved(value, it.dynamic),
        vars=it.vars,
      )
    }
  }
}

///|
/// `unzip`: `-d dir` is where the archive is extracted, and the extraction point
/// is written. Without it the working directory is the target, which this tool
/// cannot name as a path — so it reports the hole instead of the directory it
/// happens to be standing in.
fn Collector::unzip_effects(
  self : Collector,
  items : Array[PathArg],
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  let dest = flag_value(items, ["-d"])
  match dest {
    Some(d) => self.push(Write, d, false, line)
    None =>
      self.push(
        Unknown,
        "unzip: extraction point is the working directory",
        true,
        line,
      )
  }
  self.read_paths(drop_flag_value(operands, dest), line)
}

///|
/// The network tools. What leaves the machine is a URL or a host, and a host
/// does not have to look like one: for the file-transfer tools it is the operand
/// with a colon or an at-sign (`host:path`, `user@host`), for the rest the first
/// operand. `curl -o`/`wget -O` also writes a file.
fn Collector::net_effects(
  self : Collector,
  n : String,
  items : Array[PathArg],
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  for it in items {
    let t = it.text
    if t.has_prefix("http://") ||
      t.has_prefix("https://") ||
      t.has_prefix("git@") {
      self.push(Net, t, false, line)
    }
  }
  if n == "curl" || n == "wget" {
    match flag_value(items, ["-o", "-O", "--output", "--output-document"]) {
      Some(o) => self.push(Write, o, false, line)
      None => ()
    }
  }
  // A host argument is also something leaving the machine, and it does not
  // start with http. For the file-transfer tools the host is the operand
  // carrying a colon or an at-sign; for the rest, the first operand.
  if n == "scp" || n == "sftp" {
    for it in operands {
      if it.text.contains(":") || it.text.contains("@") {
        self.push(Net, it.text, it.dynamic, line)
      }
    }
  } else if n == "ssh" ||
    n == "telnet" ||
    n == "ping" ||
    n == "dig" ||
    n == "nc" ||
    n == "ncat" {
    match operands {
      [head, ..] => self.push(Net, head.text, head.dynamic, line)
      [] => ()
    }
  }
}

///|
/// `cd` is not an effect on a file, it is a change to how every later relative
/// path in this command line reads. A destination that is a hole (`$DIR`) or an
/// expansion (`~`) is not a directory this tool can name, so the base becomes
/// unknown rather than staying where it was.
fn Collector::cd_effects(
  self : Collector,
  operands : Array[PathArg],
  line : Int,
) -> Unit {
  let dest : String? = match operands {
    [first, ..] =>
      if first.dynamic || first.unrooted {
        None
      } else {
        Some(first.text)
      }
    [] => None
  }
  self.change_dir(dest, line)
}
