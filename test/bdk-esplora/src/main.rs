// BDK <-> forseti Esplora e2e harness (regtest).
// Fixed-seed wallet so every invocation is deterministic and re-scans from chain.
//
//   harness address            -> print external address #0 (mine to this)
//   harness balance            -> full_scan, print confirmed/immature/total
//   harness send <addr> <sats> -> full_scan, build+sign+broadcast, print txid

use std::str::FromStr;

use bdk_esplora::esplora_client;
use bdk_esplora::EsploraExt;
use bdk_wallet::bitcoin::bip32::Xpriv;
use bdk_wallet::bitcoin::{Address, Amount, Network};
use bdk_wallet::template::Bip84;
use bdk_wallet::{KeychainKind, SignOptions, Wallet};

const ESPLORA_URL: &str = "http://127.0.0.1:3000";
const STOP_GAP: usize = 20;
const PARALLEL: usize = 1;

fn make_wallet() -> Wallet {
    let seed = [0x21u8; 32];
    let xprv = Xpriv::new_master(Network::Regtest, &seed).expect("xprv");
    Wallet::create(
        Bip84(xprv, KeychainKind::External),
        Bip84(xprv, KeychainKind::Internal),
    )
    .network(Network::Regtest)
    .create_wallet_no_persist()
    .expect("wallet")
}

fn sync(wallet: &mut Wallet, client: &esplora_client::BlockingClient) {
    let request = wallet.start_full_scan();
    let update = client
        .full_scan(request, STOP_GAP, PARALLEL)
        .expect("full_scan");
    wallet.apply_update(update).expect("apply_update");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("balance");

    let mut wallet = make_wallet();
    let client = esplora_client::Builder::new(ESPLORA_URL)
        .build_blocking();

    match cmd {
        "address" => {
            let info = wallet.reveal_next_address(KeychainKind::External);
            println!("ADDR {}", info.address);
        }
        "balance" => {
            sync(&mut wallet, &client);
            let b = wallet.balance();
            println!(
                "BALANCE confirmed={} immature={} trusted_pending={} untrusted_pending={} total={}",
                b.confirmed.to_sat(),
                b.immature.to_sat(),
                b.trusted_pending.to_sat(),
                b.untrusted_pending.to_sat(),
                b.total().to_sat()
            );
        }
        "send" => {
            let dest = Address::from_str(&args[2])
                .expect("addr")
                .require_network(Network::Regtest)
                .expect("network");
            let sats: u64 = args[3].parse().expect("sats");
            sync(&mut wallet, &client);
            let mut builder = wallet.build_tx();
            builder.add_recipient(dest.script_pubkey(), Amount::from_sat(sats));
            let mut psbt = builder.finish().expect("finish");
            let finalized = wallet.sign(&mut psbt, SignOptions::default()).expect("sign");
            assert!(finalized, "psbt not finalized");
            let tx = psbt.extract_tx().expect("extract");
            client.broadcast(&tx).expect("broadcast");
            println!("TXID {}", tx.compute_txid());
        }
        other => {
            eprintln!("unknown command: {other}");
            std::process::exit(2);
        }
    }
}
