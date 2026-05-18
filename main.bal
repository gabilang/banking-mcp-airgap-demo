import ballerina/http;
import ballerina/io;
import ballerina/log;
import ballerina/mcp;

configurable int mcpPort = 9090;
configurable int mockCorePort = 8090;
configurable string coreBankingBaseUrl = "http://localhost:8090";
configurable decimal provisionalCreditLimit = 500.00d;

listener mcp:Listener mcpListener = check new (mcpPort);
listener http:Listener coreBankingListener = new (mockCorePort);

final http:Client coreBankingClient = check new (coreBankingBaseUrl);

type CoreTransaction record {|
    string id;
    string accountId;
    string occurredAt;
    string merchant;
    string merchantCountry;
    string channel;
    decimal amount;
    string currency;
    string cardPan;
    string customerEmail;
    boolean disputed;
|};

type TransactionView record {|
    string id;
    string occurredAt;
    string merchant;
    string merchantCountry;
    string channel;
    decimal amount;
    string currency;
    string cardLast4;
    boolean disputed;
|};

type BehaviorProfile record {|
    string accountId;
    string riskTier;
    decimal usualMaxAmount;
    string[] usualCountries;
    string[] trustedMerchants;
|};

type AccountHistory record {|
    string accountId;
    TransactionView[] transactions;
    string piiPolicy;
|};

type RiskAssessment record {|
    string accountId;
    string transactionId;
    decimal score;
    string decision;
    string[] reasons;
|};

type HoldRequest record {|
    string transactionId;
    decimal provisionalCreditAmount;
    string reason;
    string analystOrAgentRef;
|};

type HoldResponse record {|
    string accountId;
    string transactionId;
    string holdId;
    decimal provisionalCreditAmount;
    string status;
    string auditMessage;
|};

final CoreTransaction[] coreTransactions = [
    {
        id: "txn-10001",
        accountId: "acct-9001",
        occurredAt: "2026-05-16T10:15:00Z",
        merchant: "Colombo Grocery",
        merchantCountry: "LK",
        channel: "card-present",
        amount: 37.50d,
        currency: "USD",
        cardPan: "4111111111114242",
        customerEmail: "maya.perera@example.com",
        disputed: false
    },
    {
        id: "txn-10002",
        accountId: "acct-9001",
        occurredAt: "2026-05-17T03:41:00Z",
        merchant: "Night Owl Electronics",
        merchantCountry: "US",
        channel: "card-not-present",
        amount: 799.99d,
        currency: "USD",
        cardPan: "4111111111114242",
        customerEmail: "maya.perera@example.com",
        disputed: true
    },
    {
        id: "txn-10003",
        accountId: "acct-9001",
        occurredAt: "2026-05-17T05:13:00Z",
        merchant: "Metro Fuel",
        merchantCountry: "LK",
        channel: "card-present",
        amount: 62.20d,
        currency: "USD",
        cardPan: "4111111111114242",
        customerEmail: "maya.perera@example.com",
        disputed: false
    },
    {
        id: "txn-20001",
        accountId: "acct-7755",
        occurredAt: "2026-05-15T15:02:00Z",
        merchant: "Harbor Pharmacy",
        merchantCountry: "US",
        channel: "card-present",
        amount: 24.15d,
        currency: "USD",
        cardPan: "5555444433331111",
        customerEmail: "noah.chen@example.com",
        disputed: false
    }
];

@mcp:ServiceConfig {
    info: {
        name: "Banking Dispute MCP Server",
        version: "0.1.0"
    },
    sessionMode: mcp:STATELESS,
    options: {
        instructions: "Expose guarded dispute-investigation tools. Do not return raw PANs, emails, or customer names."
    }
}
service mcp:Service /mcp on mcpListener {
    @mcp:Tool {
        description: "Retrieve sanitized recent transaction history for a bank account. Card PAN and customer email are never returned."
    }
    remote function retrieveAccountHistory(string accountId) returns AccountHistory|error {
        CoreTransaction[] transactions = check coreBankingClient->get(string `/corebank/accounts/${accountId}/transactions`);

        TransactionView[] sanitized = from CoreTransaction txn in transactions
            select toTransactionView(txn);

        return {
            accountId,
            transactions: sanitized,
            piiPolicy: "Raw card PAN and customer email were removed by the integration layer before MCP exposure."
        };
    }

    @mcp:Tool {
        description: "Assess whether a disputed transaction is anomalous against the account behavior profile."
    }
    remote function assessDisputeRisk(string accountId, string transactionId) returns RiskAssessment|error {
        return assessRiskFor(accountId, transactionId);
    }

    @mcp:Tool {
        description: "Place a guarded account hold and issue a provisional credit after high-risk fraud is detected."
    }
    remote function placeFraudHold(string accountId, string transactionId, decimal provisionalCreditAmount,
            string analystOrAgentRef) returns HoldResponse|error {
        if provisionalCreditAmount <= 0.00d {
            return error("Provisional credit amount must be positive.");
        }
        if provisionalCreditAmount > provisionalCreditLimit {
            return error(string `Provisional credit exceeds the demo limit of ${provisionalCreditLimit}.`);
        }

        RiskAssessment assessment = check assessRiskFor(accountId, transactionId);
        if assessment.score < 0.70d {
            return error(string `Risk score ${assessment.score} is below the required threshold for autonomous hold placement.`);
        }

        HoldRequest holdRequest = {
            transactionId,
            provisionalCreditAmount,
            reason: string `AI fraud assessment: ${assessment.decision}`,
            analystOrAgentRef
        };

        return check coreBankingClient->post(string `/corebank/accounts/${accountId}/holds`, holdRequest);
    }
}

service /corebank on coreBankingListener {
    resource function get accounts/[string accountId]/transactions() returns CoreTransaction[]|http:NotFound {
        CoreTransaction[] accountTransactions = from CoreTransaction txn in coreTransactions
            where txn.accountId == accountId
            select txn;

        if accountTransactions.length() == 0 {
            return notFound(string `No transactions found for account ${accountId}`);
        }
        return accountTransactions;
    }

    resource function get accounts/[string accountId]/behaviorProfile() returns BehaviorProfile|http:NotFound {
        BehaviorProfile|error profile = findBehaviorProfile(accountId);
        if profile is BehaviorProfile {
            return profile;
        }
        return notFound(string `No behavior profile found for account ${accountId}`);
    }

    resource function post accounts/[string accountId]/holds(HoldRequest holdRequest)
            returns HoldResponse|http:NotFound|http:BadRequest {
        CoreTransaction[] accountTransactions = from CoreTransaction txn in coreTransactions
            where txn.accountId == accountId
            select txn;

        if accountTransactions.length() == 0 {
            return notFound(string `No account found for ${accountId}`);
        }

        CoreTransaction|error txn = findTransaction(accountTransactions, holdRequest.transactionId);
        if txn is error {
            return badRequest(txn.message());
        }

        string holdId = string `hold-${accountId}-${holdRequest.transactionId}`;
        log:printInfo("Legacy hold created", accountId = accountId, transactionId = holdRequest.transactionId,
            holdId = holdId, agent = holdRequest.analystOrAgentRef);

        return {
            accountId,
            transactionId: holdRequest.transactionId,
            holdId,
            provisionalCreditAmount: holdRequest.provisionalCreditAmount,
            status: "PLACED",
            auditMessage: "Hold was accepted by the mock core banking API. In production this call travels through the Tailscale proxy."
        };
    }
}

function toTransactionView(CoreTransaction txn) returns TransactionView {
    return {
        id: txn.id,
        occurredAt: txn.occurredAt,
        merchant: txn.merchant,
        merchantCountry: txn.merchantCountry,
        channel: txn.channel,
        amount: txn.amount,
        currency: txn.currency,
        cardLast4: txn.cardPan.substring(txn.cardPan.length() - 4),
        disputed: txn.disputed
    };
}

function assessRiskFor(string accountId, string transactionId) returns RiskAssessment|error {
    CoreTransaction[] transactions = check coreBankingClient->get(string `/corebank/accounts/${accountId}/transactions`);
    BehaviorProfile profile = check coreBankingClient->get(string `/corebank/accounts/${accountId}/behaviorProfile`);

    CoreTransaction txn = check findTransaction(transactions, transactionId);
    return scoreTransaction(txn, profile);
}

function scoreTransaction(CoreTransaction txn, BehaviorProfile profile) returns RiskAssessment {
    decimal score = 0.10d;
    string[] reasons = [];

    if txn.disputed {
        score += 0.25d;
        reasons.push("Customer disputed the transaction.");
    }
    if txn.amount > profile.usualMaxAmount {
        score += 0.30d;
        reasons.push(string `Amount ${txn.amount} exceeds usual max ${profile.usualMaxAmount}.`);
    }
    if !contains(profile.usualCountries, txn.merchantCountry) {
        score += 0.20d;
        reasons.push(string `Merchant country ${txn.merchantCountry} is outside the usual countries.`);
    }
    if !contains(profile.trustedMerchants, txn.merchant) {
        score += 0.15d;
        reasons.push("Merchant is not in the trusted merchant profile.");
    }
    if txn.channel == "card-not-present" {
        score += 0.10d;
        reasons.push("Card-not-present transaction has higher fraud exposure.");
    }

    if score > 1.00d {
        score = 1.00d;
    }

    string decision = score >= 0.70d ? "HIGH_RISK_HOLD_RECOMMENDED" : score >= 0.45d ? "REVIEW_MANUALLY" : "LOW_RISK";
    return {
        accountId: txn.accountId,
        transactionId: txn.id,
        score,
        decision,
        reasons
    };
}

function findTransaction(CoreTransaction[] transactions, string transactionId) returns CoreTransaction|error {
    foreach CoreTransaction txn in transactions {
        if txn.id == transactionId {
            return txn;
        }
    }
    return error(string `Transaction ${transactionId} not found.`);
}

function findBehaviorProfile(string accountId) returns BehaviorProfile|error {
    match accountId {
        "acct-9001" => {
            return {
                accountId: "acct-9001",
                riskTier: "medium",
                usualMaxAmount: 250.00d,
                usualCountries: ["LK"],
                trustedMerchants: ["Colombo Grocery", "Metro Fuel"]
            };
        }
        "acct-7755" => {
            return {
                accountId: "acct-7755",
                riskTier: "low",
                usualMaxAmount: 150.00d,
                usualCountries: ["US"],
                trustedMerchants: ["Harbor Pharmacy"]
            };
        }
        _ => {
            return error(string `No behavior profile found for account ${accountId}.`);
        }
    }
}

function contains(string[] values, string candidate) returns boolean {
    foreach string value in values {
        if value == candidate {
            return true;
        }
    }
    return false;
}

function notFound(string message) returns http:NotFound {
    return {body: {message}};
}

function badRequest(string message) returns http:BadRequest {
    return {body: {message}};
}

public function main() {
    io:println(string `Banking MCP server listening at http://localhost:${mcpPort}/mcp`);
    io:println(string `Mock core banking API listening at http://localhost:${mockCorePort}/corebank`);
}
