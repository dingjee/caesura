// Copyright (c) 2025 Jonas van den Berg
// This file is licensed under the BSD 3-Clause License.
//
// Caesura addition (narrow patch, see UPSTREAM.md): the guarded command.
//
// The upstream adapter reads the now playing information and sends a command
// in two separate processes, so the media session can change between the read
// and the command. The guarded command does both in one process: it reads the
// session, verifies the guard and sends the command right away. Nothing of the
// media itself (no title, no address) leaves this process — only the identity
// of the session and the state.

#ifndef MEDIAREMOTEADAPTER_ADAPTER_GUARDED_H
#define MEDIAREMOTEADAPTER_ADAPTER_GUARDED_H

#import <Foundation/Foundation.h>

// Reads the current now playing session and prints its identity and its state
// as one JSON line. The metadata of the media is reduced to a fingerprint.
extern void adapter_guarded_read();

// Reads the current now playing session, verifies the guard and sends the
// command in the same process.
//
// The parameters come from the environment:
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_action       read | pause | play
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_bundle       expected bundle id
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_parent       expected parent id
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_process      expected process id
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_item         expected media item
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_allowed      apps that keep playing
//   MEDIAREMOTEADAPTER_PARAM_adapter_guarded_0_dryrun       "1" sends nothing
extern void adapter_guarded_env();

#endif // MEDIAREMOTEADAPTER_ADAPTER_GUARDED_H
