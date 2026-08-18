use rocksdb::{Direction, IteratorMode, Options, DB};
use std::{collections::BTreeMap, env, error::Error, fs::File, io::{BufWriter, Write}, path::PathBuf};

const SERVICE_BURN_PREFIX: u8 = 196;

fn hex(bytes: &[u8]) -> String {
    const LUT: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(LUT[(b >> 4) as usize] as char);
        out.push(LUT[(b & 0x0f) as usize] as char);
    }
    out
}

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = env::args_os().skip(1);
    let db_path = args.next().map(PathBuf::from).ok_or(
        "usage: service_burn_dump.exe <consensus-db-path> [output.csv]",
    )?;
    let output = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("service-burn-dump.csv"));

    if args.next().is_some() {
        return Err("too many arguments; usage: service_burn_dump.exe <consensus-db-path> [output.csv]".into());
    }
    if !db_path.is_dir() {
        return Err(format!("database path does not exist or is not a directory: {}", db_path.display()).into());
    }

    // Hard safety boundary: the RocksDB handle is opened read-only. This program contains no
    // put/delete/write-batch calls and cannot create a missing database.
    let opts = Options::default();
    let db = DB::open_for_read_only(&opts, &db_path, false)?;

    let file = File::create(&output)?;
    let mut out = BufWriter::new(file);
    writeln!(out, "txid,index,miss_daa")?;

    let prefix = [SERVICE_BURN_PREFIX];
    let mut rows = 0u64;
    let mut by_daa: BTreeMap<u64, u64> = BTreeMap::new();

    for item in db.iterator(IteratorMode::From(&prefix, Direction::Forward)) {
        let (key, value) = item?;
        if key.first().copied() != Some(SERVICE_BURN_PREFIX) {
            break;
        }

        // Database key layout: [prefix=196][txid:32][index:4 LE].
        if key.len() != 1 + 36 {
            eprintln!("warning: skipping malformed ServiceBurn key of {} bytes", key.len());
            continue;
        }
        let txid = hex(&key[1..33]);
        let index = u32::from_le_bytes(key[33..37].try_into()?);
        let miss_daa: u64 = bincode::deserialize(&value)?;

        writeln!(out, "{txid},{index},{miss_daa}")?;
        rows += 1;
        *by_daa.entry(miss_daa).or_default() += 1;
    }
    out.flush()?;

    println!("READ-ONLY ServiceBurn dump complete");
    println!("database : {}", db_path.display());
    println!("output   : {}", output.display());
    println!("rows     : {rows}");
    println!("distinct miss_daa values: {}", by_daa.len());
    for (daa, count) in by_daa {
        println!("  miss_daa={daa} burned_outpoints={count}");
    }

    Ok(())
}
