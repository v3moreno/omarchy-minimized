/*
 * This is the decision half of minimize. It deliberately has no filesystem
 * or subprocess dependency: Service.qml loads this exact file and supplies
 * all of the IO around it.
 */

var MINIMIZED_WORKSPACE = "special:minimized";
var WORKSPACE_ID = /^(?:0|[1-9][0-9]*)$/;
var WINDOW_ADDRESS = /^0x[0-9a-fA-F]+$/;

function own(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function requireClients(clients) {
    if (!Array.isArray(clients)) {
        throw new TypeError("hyprctl clients must be an array.");
    }
}

function requireState(state) {
    if (!state || typeof state !== "object" || Array.isArray(state) ||
            !state.modes || typeof state.modes !== "object" || Array.isArray(state.modes) ||
            !state.minimized || typeof state.minimized !== "object" || Array.isArray(state.minimized)) {
        throw new TypeError("Minimize state must contain modes and minimized objects.");
    }
}

function requireAddress(address) {
    if (typeof address !== "string" || !WINDOW_ADDRESS.test(address)) {
        throw new TypeError("Window address must be a hexadecimal 0x address.");
    }
}

function copyState(state) {
    var copy = { modes: {}, minimized: {} };
    var key;

    requireState(state);
    Object.keys(state.modes).forEach(function (workspaceId) {
        copy.modes[workspaceId] = state.modes[workspaceId];
    });
    Object.keys(state.minimized).forEach(function (address) {
        copy.minimized[address] = {
            origin: state.minimized[address].origin,
            title: state.minimized[address].title,
            "class": state.minimized[address]["class"]
        };
    });
    return copy;
}

function clientAtAddress(clients, address) {
    var index;

    requireClients(clients);
    requireAddress(address);
    for (index = 0; index < clients.length; index += 1) {
        if (clients[index] && clients[index].address === address) {
            return clients[index];
        }
    }
    return null;
}

function clientWorkspaceName(client) {
    if (!client || typeof client !== "object" || !client.workspace ||
            typeof client.workspace !== "object" || typeof client.workspace.name !== "string") {
        return null;
    }
    return client.workspace.name;
}

function minimizedClients(clients) {
    requireClients(clients);
    return clients.filter(function (client) {
        return clientWorkspaceName(client) === MINIMIZED_WORKSPACE;
    });
}

function staleAddresses(state, clients) {
    requireState(state);
    return Object.keys(state.minimized).filter(function (address) {
        var client = clientAtAddress(clients, address);
        // Live but no longer parked is stale too: the window may have been
        // moved off the special workspace by hand or by another rule.
        return !client || clientWorkspaceName(client) !== MINIMIZED_WORKSPACE;
    }).sort();
}

function prune(state, clients) {
    var nextState = copyState(state);
    var stale = staleAddresses(state, clients);

    stale.forEach(function (address) {
        delete nextState.minimized[address];
    });
    return { state: nextState, staleAddresses: stale };
}

function minimizeRecord(client) {
    var address;
    var origin;

    if (!client || typeof client !== "object") {
        throw new TypeError("Cannot minimize a missing client.");
    }
    address = client.address;
    origin = clientWorkspaceName(client);
    requireAddress(address);
    if (typeof origin !== "string" || !WORKSPACE_ID.test(origin)) {
        throw new TypeError("A minimized window must originate on a numbered workspace.");
    }
    return {
        origin: origin,
        title: typeof client.title === "string" ? client.title : "",
        "class": typeof client["class"] === "string" ? client["class"] : ""
    };
}

function moveCommand(address, workspace) {
    requireAddress(address);
    if (workspace !== MINIMIZED_WORKSPACE &&
            (typeof workspace !== "string" || !WORKSPACE_ID.test(workspace))) {
        throw new TypeError("Move target must be special:minimized or a numbered workspace.");
    }
    // Omarchy's `hyprctl dispatch` wraps the argument in hl.dispatch(...)
    // itself — passing hl.dispatch(hl.dsp...) double-wraps, which moves the
    // window but exits nonzero.
    return "hl.dsp.window.move({ workspace = " + JSON.stringify(workspace) +
        ", window = \"address:" + address + "\", follow = false })";
}

function planMinimize(state, clients, address) {
    var client;
    var record;
    var nextState;

    requireState(state);
    client = clientAtAddress(clients, address);
    if (!client) {
        return { ok: false, reason: "dead-address", address: address };
    }
    if (clientWorkspaceName(client) === MINIMIZED_WORKSPACE) {
        return { ok: false, reason: "already-minimized", address: address };
    }

    record = minimizeRecord(client);
    nextState = copyState(state);
    nextState.minimized[address] = record;
    return {
        ok: true,
        address: address,
        record: record,
        command: moveCommand(address, MINIMIZED_WORKSPACE),
        state: nextState
    };
}

function planRestore(state, clients, address, fallbackWorkspace) {
    var record;
    var client;
    var origin;
    var nextState;

    requireState(state);
    requireAddress(address);

    client = clientAtAddress(clients, address);
    if (!client) {
        // A dead address reports success from Hyprland, so do not dispatch it.
        nextState = copyState(state);
        delete nextState.minimized[address];
        return { ok: false, reason: "dead-address", address: address, state: nextState };
    }
    if (clientWorkspaceName(client) !== MINIMIZED_WORKSPACE) {
        return { ok: false, reason: "not-minimized", address: address, state: copyState(state) };
    }

    record = own(state.minimized, address) ? state.minimized[address] : null;
    // A window parked outside our bookkeeping (state loss, manual move) still
    // restores — to wherever the user is looking rather than a recorded origin.
    origin = record ? record.origin : fallbackWorkspace;
    if (typeof origin !== "string" || !WORKSPACE_ID.test(origin)) {
        return { ok: false, reason: "no-origin", address: address, state: copyState(state) };
    }

    nextState = copyState(state);
    delete nextState.minimized[address];
    return {
        ok: true,
        address: address,
        origin: origin,
        record: record,
        command: moveCommand(address, origin),
        // The IO caller writes this only after the move is verified.
        state: nextState
    };
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        MINIMIZED_WORKSPACE: MINIMIZED_WORKSPACE,
        WINDOW_ADDRESS: WINDOW_ADDRESS,
        clientAtAddress: clientAtAddress,
        clientWorkspaceName: clientWorkspaceName,
        minimizedClients: minimizedClients,
        minimizeRecord: minimizeRecord,
        moveCommand: moveCommand,
        planMinimize: planMinimize,
        planRestore: planRestore,
        prune: prune,
        staleAddresses: staleAddresses
    };
}
