// Command genvectors emits golden wire vectors for the Android client's interop
// tests.
//
// The vectors are produced by the RELAY'S OWN generated Go protobuf types — the
// same ones the server links — so a byte-equality assertion on the Android side
// proves the Kotlin codegen agrees with the Go codegen about every field number
// and encoding. If a .proto changes, regenerate:
//
//	cd android/tools/genvectors
//	~/sdk/go/bin/go run . -kind=wire   > ../../proto/src/test/resources/golden/wire-vectors.json
//	~/sdk/go/bin/go run . -kind=crypto > ../../crypto/src/test/resources/golden/crypto-vectors.json
//
// Nothing here writes to ../../../server; the module only imports it.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	contentpb "github.com/relayapp/relay-server/gen/contentpb"
	relaypb "github.com/relayapp/relay-server/gen/relaypb"
	"google.golang.org/protobuf/proto"
)

type vector struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Notes string `json:"notes,omitempty"`
	Bytes string `json:"bytes"`
}

// repeat builds a deterministic n-byte filler so vectors stay stable.
func repeat(b byte, n int) []byte { return bytes.Repeat([]byte{b}, n) }

func main() {
	kind := flag.String("kind", "wire", "which vector set to emit: wire | crypto")
	flag.Parse()

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")

	if *kind == "crypto" {
		if err := enc.Encode(cryptoVectors()); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}

	var vectors []vector
	add := func(name, notes string, m proto.Message) {
		raw, err := proto.Marshal(m)
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal %s: %v\n", name, err)
			os.Exit(1)
		}
		vectors = append(vectors, vector{
			Name:  name,
			Type:  string(m.ProtoReflect().Descriptor().FullName()),
			Notes: notes,
			Bytes: base64.StdEncoding.EncodeToString(raw),
		})
	}

	// ---- relay.content.Content -------------------------------------------

	add("content_text_full",
		"every top-level Content field set at once: body oneof + group_id(8), padding(12), sender ids(13,14), expires_after_ms(15), sync_recipient(16)",
		&contentpb.Content{
			Body: &contentpb.Content_Text{Text: &contentpb.TextMessage{
				Body:      "hello ✓",
				Timestamp: 1758000000000,
				Quote: &contentpb.Quote{
					TargetTimestamp: 1757999999000,
					Author:          "acct-a",
					Text:            "prior message",
				},
				Attachments: []*contentpb.AttachmentPointer{{
					Id:          "blob-1",
					Key:         repeat(0x01, 32),
					Digest:      repeat(0x02, 32),
					ContentType: "image/jpeg",
					Size:        4096,
					Filename:    "photo.jpg",
					Width:       800,
					Height:      600,
				}},
			}},
			GroupId:         "group-1",
			Padding:         repeat(0xAA, 8),
			SenderAccountId: "acct-sender",
			SenderDeviceId:  3,
			ExpiresAfterMs:  86400000,
			SyncRecipient:   "acct-peer",
		})

	add("content_text_minimal",
		"proto3 default elision: empty body string and zero timestamp emit nothing",
		&contentpb.Content{
			Body: &contentpb.Content_Text{Text: &contentpb.TextMessage{}},
		})

	add("content_receipt_read", "read receipt over three sender timestamps",
		&contentpb.Content{
			Body: &contentpb.Content_Receipt{Receipt: &contentpb.ReceiptMessage{
				Type:              contentpb.ReceiptMessage_TYPE_READ,
				MessageTimestamps: []int64{1758000000001, 1758000000002, 1758000000003},
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  1,
		})

	add("content_typing_started", "ephemeral typing indicator",
		&contentpb.Content{
			Body: &contentpb.Content_Typing{Typing: &contentpb.TypingMessage{
				Action:    contentpb.TypingMessage_ACTION_STARTED,
				Timestamp: 1758000000000,
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  1,
		})

	add("content_reaction", "multi-byte emoji payload",
		&contentpb.Content{
			Body: &contentpb.Content_Reaction{Reaction: &contentpb.ReactionMessage{
				Emoji:           "\U0001F389",
				TargetAuthor:    "acct-a",
				TargetTimestamp: 1758000000000,
				Remove:          false,
				Timestamp:       1758000000500,
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  2,
		})

	add("content_group_update_add",
		"full roster + admins + rotated distribution_id(11) + invite_key(12)",
		&contentpb.Content{
			Body: &contentpb.Content_GroupUpdate{GroupUpdate: &contentpb.GroupUpdate{
				Revision:       7,
				Action:         contentpb.GroupUpdate_ADD,
				Actor:          "acct-admin",
				Target:         "acct-new",
				Members:        []string{"acct-admin", "acct-b", "acct-new"},
				Admins:         []string{"acct-admin"},
				AnnounceOnly:   true,
				DistributionId: "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff",
				InviteKey:      repeat(0x33, 32),
			}},
			GroupId:         "group-1",
			SenderAccountId: "acct-admin",
			SenderDeviceId:  1,
		})

	add("content_sender_key_distribution", "SKDM carried over a pairwise session",
		&contentpb.Content{
			Body: &contentpb.Content_SenderKeyDistribution{
				SenderKeyDistribution: &contentpb.SenderKeyDistribution{
					Data:           repeat(0x44, 48),
					DistributionId: "6f1a2b3c-4d5e-4f60-8899-aabbccddeeff",
				},
			},
			GroupId: "group-1",
		})

	add("content_delete", "unsend / delete-for-everyone",
		&contentpb.Content{
			Body: &contentpb.Content_Delete{Delete: &contentpb.DeleteMessage{
				TargetTimestamp: 1758000000000,
				TargetAuthor:    "acct-sender",
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  1,
		})

	add("content_edit", "in-place edit of an earlier message",
		&contentpb.Content{
			Body: &contentpb.Content_Edit{Edit: &contentpb.EditMessage{
				TargetTimestamp: 1758000000000,
				NewBody:         "edited body",
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  1,
		})

	add("content_profile", "E2EE profile distribution with an avatar pointer",
		&contentpb.Content{
			Body: &contentpb.Content_Profile{Profile: &contentpb.ProfileUpdate{
				DisplayName: "Ethan",
				Avatar: &contentpb.AttachmentPointer{
					Id:          "blob-avatar",
					Key:         repeat(0x05, 32),
					Digest:      repeat(0x06, 32),
					ContentType: "image/jpeg",
					Size:        2048,
				},
				Timestamp: 1758000000000,
				Status:    "Building Relay",
				Bio:       "Long-form bio text, end-to-end encrypted like everything else.",
			}},
		})

	add("content_call_offer",
		"CallMessage.Type OFFER == 0, so proto3 elides the type field entirely -- receivers must default to OFFER",
		&contentpb.Content{
			Body: &contentpb.Content_Call{Call: &contentpb.CallMessage{
				Type:   contentpb.CallMessage_OFFER,
				CallId: "call-1",
				Sdp:    "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n",
			}},
			SenderAccountId: "acct-sender",
			SenderDeviceId:  1,
		})

	add("content_call_group_ring", "group ring with a participant list",
		&contentpb.Content{
			Body: &contentpb.Content_Call{Call: &contentpb.CallMessage{
				Type:         contentpb.CallMessage_GROUP_RING,
				CallId:       "call-2",
				GroupId:      "group-1",
				Participants: []string{"acct-a", "acct-b", "acct-c"},
			}},
			GroupId: "group-1",
		})

	add("content_poll", "field 17 -- two-byte tag",
		&contentpb.Content{
			Body: &contentpb.Content_Poll{Poll: &contentpb.PollMessage{
				Question:    "Lunch?",
				Options:     []string{"Thai", "Sushi", "Burgers"},
				MultiSelect: true,
				Timestamp:   1758000000000,
			}},
			GroupId: "group-1",
		})

	add("content_poll_vote", "field 18 -- two-byte tag, packed repeated uint32",
		&contentpb.Content{
			Body: &contentpb.Content_PollVote{PollVote: &contentpb.PollVote{
				PollAuthor:      "acct-a",
				PollTimestamp:   1758000000000,
				SelectedOptions: []uint32{0, 2},
				Timestamp:       1758000001000,
			}},
			GroupId: "group-1",
		})

	// ---- relay.v1 ---------------------------------------------------------

	add("client_frame_send",
		"mailbox-addressed send: destination_account holds an opaque mailbox id and messages carries exactly one DeviceMessage",
		&relaypb.ClientFrame{
			Id: 42,
			Payload: &relaypb.ClientFrame_Send{Send: &relaypb.SendRequest{
				DestinationAccount: "mbx-0123456789abcdef",
				Messages: []*relaypb.DeviceMessage{{
					DeviceId:       2,
					RegistrationId: 12345,
					Type:           relaypb.CiphertextType_CIPHERTEXT_TYPE_PREKEY_MESSAGE,
					Content:        repeat(0x77, 64),
				}},
				ClientTimestamp: 1758000000000,
				Ephemeral:       false,
			}},
		})

	add("client_frame_ack", "envelope ack",
		&relaypb.ClientFrame{
			Payload: &relaypb.ClientFrame_Ack{Ack: &relaypb.AckRequest{
				EnvelopeId: "0123456789abcdef0123456789abcdef",
			}},
		})

	add("envelope_sealed",
		"sealed sender: sender_account(2) and sender_device(3) are empty/zero and therefore absent from the wire",
		&relaypb.Envelope{
			Id:              "0123456789abcdef0123456789abcdef",
			Type:            relaypb.CiphertextType_CIPHERTEXT_TYPE_MESSAGE,
			Content:         repeat(0x88, 32),
			ClientTimestamp: 1758000000000,
			ServerTimestamp: 1758000000123,
		})

	add("envelope_unsealed_ephemeral", "authenticated send, ephemeral (never queued)",
		&relaypb.Envelope{
			Id:              "fedcba9876543210fedcba9876543210",
			SenderAccount:   "acct-sender",
			SenderDevice:    1,
			Type:            relaypb.CiphertextType_CIPHERTEXT_TYPE_MESSAGE,
			Content:         repeat(0x99, 16),
			ClientTimestamp: 1758000000000,
			ServerTimestamp: 1758000000123,
			Ephemeral:       true,
		})

	add("server_frame_mismatched_devices",
		"the missing/extra/stale lists the client's retry algorithm depends on",
		&relaypb.ServerFrame{
			Payload: &relaypb.ServerFrame_SendResponse{SendResponse: &relaypb.SendResponse{
				ReplyTo:         42,
				Status:          relaypb.SendStatus_SEND_STATUS_MISMATCHED_DEVICES,
				MissingDevices:  []uint32{2, 3},
				ExtraDevices:    []uint32{9},
				StaleDevices:    []uint32{4},
				ServerTimestamp: 1758000000123,
			}},
		})

	add("server_frame_queue_empty", "end-of-backlog marker",
		&relaypb.ServerFrame{
			Payload: &relaypb.ServerFrame_QueueEmpty{QueueEmpty: &relaypb.QueueEmpty{}},
		})

	add("server_frame_nuke", "signed remote-wipe command relayed to every device",
		&relaypb.ServerFrame{
			Payload: &relaypb.ServerFrame_Nuke{Nuke: &relaypb.NukeCommand{
				AccountId:          "acct-sender",
				CommandId:          "11112222-3333-4444-5555-666677778888",
				CreationTimeMs:     1758000000000,
				InitiatingDeviceId: 1,
				Signature:          repeat(0xEE, 70),
			}},
		})

	add("server_frame_device_list_changed", "device-list change hint",
		&relaypb.ServerFrame{
			Payload: &relaypb.ServerFrame_DeviceListChanged{
				DeviceListChanged: &relaypb.DeviceListChanged{
					Action:   relaypb.DeviceListChanged_DEVICE_ADDED,
					DeviceId: 5,
				},
			},
		})

	out := map[string]any{
		"_comment": "GENERATED FILE -- do not edit. Produced by android/tools/genvectors " +
			"from the relay's own Go protobuf types. Regenerate after any change to proto/.",
		"protoSources": []string{"proto/relay.proto", "proto/content.proto"},
		"vectors":      vectors,
	}
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
