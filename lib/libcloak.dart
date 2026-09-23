/// The TSL1_SP shielded pool wallet library.
///
/// libcloak holds keys, notes, invoices and payments for one person paying
/// another out of a TSL1_SP pool. It is headless: no daemon, no sockets, no
/// UI. A host builds a wallet, hands it a [HeaderSource] and a [Transport],
/// and calls it.
///
/// Two rules run through everything here:
///
/// **People pay people.** A payment is delivered, with its proof, in
/// consideration of something. Nobody scans a chain looking for money: the
/// payer hands the payee a proof, the payee checks it against block headers it
/// already holds, and the goods change hands. The library asks no server what
/// it owns, and the only exception the rule will ever have is recovering a
/// wallet from its seed, which is not in this change.
///
/// **Nothing is taken on trust.** Every answer a pool gives is checked against
/// something the wallet proved for itself: a block root against the commitment
/// root of a round proved off the chain, a round against a header the wallet's
/// own source vouches for. So a pool is a convenient server and never an
/// authority, and a wallet that got the same bytes from a stranger reaches the
/// same verdict.
library;

export 'src/headers/header_source.dart' show HeaderSource, ChainTip, HeaderSourceFailure;
export 'src/keys/seed.dart' show WalletSeed;
export 'src/keys/wallet_file.dart' show WalletFile, WalletFileNotice, WalletKdf, StoredWallet;
export 'src/keys/wallet_keys.dart' show WalletKeys, AddressCodec;
export 'src/headers/merkle_membership.dart' show MerkleMembership, MerkleProof;
export 'src/headers/proven_header.dart' show HeaderChecker, ProvenHeader;
export 'src/msg/codec.dart' show Reader, Writer;
export 'src/msg/payment_proof.dart' show PaymentProof, ProofForm, NoteOpening;
export 'src/notes/balance.dart' show Balance;
export 'src/notes/note.dart' show HeldNote, NoteState;
export 'src/notes/note_store.dart' show NoteStore, NoteStoreFile;
export 'src/notes/selection.dart' show NoteChoice, NoteSelection;
export 'src/pool/descriptor.dart' show PoolShape;
export 'src/pool/frontier.dart' show Checkpoint, UpperFrontier;
export 'src/pool/note_path.dart' show TrackedNote;
export 'src/pool/pool_view.dart' show PoolView, PoolViewFile;
export 'src/net/transport.dart' show Transport, FeedEntry, TransportFailure;
export 'src/pay/checker.dart' show PaymentChecker, CheckedPayment;
export 'src/refusal.dart' show Refusal, shortHex;
