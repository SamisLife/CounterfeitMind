import express from "express";
import cors from "cors";
import fs from "fs";
import { ethers } from "ethers";


const app = express();
app.use(cors());
app.use(express.json());

const ABI = JSON.parse(fs.readFileSync("./abi.json", "utf8"));

const RPC_URL =
  process.env.RPC_URL ||
  "";

const PRIVATE_KEY =
  process.env.PRIVATE_KEY ||
  "";

const CONTRACT_ADDRESS =
  process.env.CONTRACT_ADDRESS || "";

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

function canonicalMessage(serial, currency, value) {
  return `serial=${serial}|currency=${currency}|value=${value}`;
}

function computeBillHash(serial, currency, value) {
  const msg = canonicalMessage(serial, currency, value);
  return ethers.keccak256(ethers.toUtf8Bytes(msg));
}

function normalizeBillInput(body) {
  const serialRaw = body?.serial;
  const currencyRaw = body?.currency;
  const valueRaw = body?.value;

  const serial =
    typeof serialRaw === "string" ? serialRaw.trim() : "";
  const currency =
    typeof currencyRaw === "string" ? currencyRaw.trim().toUpperCase() : "";
  const value =
    typeof valueRaw === "number" ? valueRaw : Number(valueRaw);

  const pubkeyB64 =
    typeof body?.pubkeyB64 === "string" ? body.pubkeyB64.trim() : "";

  return { serial, currency, value, pubkeyB64 };
}


app.get("/health", async (req, res) => {
  try {
    const [bal, net] = await Promise.all([
      provider.getBalance(wallet.address),
      provider.getNetwork()
    ]);

    res.json({
      ok: true,
      treasury: wallet.address,
      balanceEth: ethers.formatEther(bal),
      contract: CONTRACT_ADDRESS,
      chainId: Number(net.chainId)
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});

app.post("/register", async (req, res) => {
  try {
    const { serial, currency, value, pubkeyB64 } = normalizeBillInput(req.body);

    if (!serial || !currency || !Number.isFinite(value)) {
      return res.status(400).json({ ok: false, error: "Missing serial/currency/value" });
    }

    if (value <= 0) {
      return res.status(400).json({ ok: false, error: "Value must be > 0" });
    }

    if (pubkeyB64) {
      console.log("🔑 pubkeyB64 (demo):", pubkeyB64);
    }

    const issued = await contract.isIssued(serial);
    if (issued) {
      const [billHash, issuedAt] = await contract.getBill(serial);
      return res.json({
        ok: true,
        already: true,
        issued: true,
        serial,
        billHash,
        issuedAt: Number(issuedAt)
      });
    }

    const billHash = computeBillHash(serial, currency, value);

    const tx = await contract.registerBill(serial, billHash);
    const receipt = await tx.wait();

    const [storedHash, issuedAt] = await contract.getBill(serial);

    res.json({
      ok: true,
      already: false,
      issued: true,
      serial,
      billHash: storedHash,
      issuedAt: Number(issuedAt),
      txHash: tx.hash,
      blockNumber: receipt.blockNumber
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});

app.get("/bill/:serial?", async (req, res) => {
  try {
    const serialFromParam = req.params.serial;
    const serialFromQuery = req.query.serial;

    const serial =
      typeof serialFromParam === "string" && serialFromParam.trim()
        ? serialFromParam.trim()
        : (typeof serialFromQuery === "string" ? serialFromQuery.trim() : "");

    if (!serial) {
      return res.status(400).json({ ok: false, error: "Missing serial" });
    }

    const issued = await contract.isIssued(serial);
    if (!issued) {
      return res.json({ ok: true, issued: false, serial });
    }

    const [billHash, issuedAt] = await contract.getBill(serial);

    res.json({
      ok: true,
      issued: true,
      serial,
      billHash,
      issuedAt: Number(issuedAt)
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message || e) });
  }
});


app.listen(8787, "0.0.0.0", () => {
  console.log("listening on http://0.0.0.0:8787");
  console.log("   Endpoints:");
  console.log("   - GET  /health");
  console.log("   - POST /register   {serial,currency,value,pubkeyB64?}");
  console.log("   - GET  /bill/TEST");
  console.log("   - GET  /bill?serial=TEST");
});
