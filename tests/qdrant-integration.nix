# Qdrant Integration Test for ARM RAG Support
#
# This test verifies:
# 1. Qdrant service starts and responds on health endpoint
# 2. Qdrant REST API is functional
# 3. On-disk storage mode works correctly
#
# Note: Open-WebUI integration is tested via flake check (rpi5-full config)
#       due to unfree license constraints in standalone tests.
#
# Run with: nix-build tests/qdrant-integration.nix

{ pkgs ? import <nixpkgs> { } }:

pkgs.testers.nixosTest {
  name = "qdrant-integration-test";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [
      ../modules/services/qdrant.nix
    ];

    # Qdrant service configuration
    services.qdrant-tailscale = {
      enable = true;
      port = 6333;
      grpcPort = 6334;

      # Use on-disk storage for low memory footprint (critical for RPi5)
      storage.onDisk = true;

      # Disable Tailscale Serve in test VM
      tailscaleServe.enable = false;
    };

    # Required packages for testing
    environment.systemPackages = with pkgs; [
      curl
      jq
    ];

    networking.firewall.allowedTCPPorts = [ 6333 6334 ];
  };

  testScript = ''
    start_all()

    # ================================================================
    # Test 1: Qdrant service starts and is healthy
    # ================================================================
    print("Waiting for Qdrant service...")
    machine.wait_for_unit("qdrant.service")
    machine.wait_for_open_port(6333)

    print("Checking Qdrant root endpoint...")
    # Qdrant root endpoint returns 200 OK (no /health endpoint in default setup)
    machine.succeed("curl -sf http://127.0.0.1:6333/ | jq -e '.title'")
    print("Qdrant is responding!")

    # ================================================================
    # Test 2: Qdrant REST API is functional
    # ================================================================
    print("Testing Qdrant collections endpoint...")
    collections_response = machine.succeed("curl -sf http://127.0.0.1:6333/collections")
    print(f"Collections response: {collections_response}")

    # Should return JSON with collections array
    machine.succeed("curl -sf http://127.0.0.1:6333/collections | jq -e '.result.collections'")
    print("Qdrant REST API test passed!")

    # ================================================================
    # Test 3: Qdrant gRPC port is open (for high-performance operations)
    # ================================================================
    print("Checking Qdrant gRPC port...")
    machine.wait_for_open_port(6334)
    print("Qdrant gRPC port is open!")

    # ================================================================
    # Test 4: Create a test collection (verify write operations)
    # ================================================================
    print("Creating test collection...")
    create_result = machine.succeed("""
      curl -sf -X PUT http://127.0.0.1:6333/collections/test_collection \
        -H 'Content-Type: application/json' \
        -d '{"vectors": {"size": 4, "distance": "Cosine"}}'
    """)
    print(f"Create collection result: {create_result}")

    # Verify collection exists
    machine.succeed("curl -sf http://127.0.0.1:6333/collections/test_collection | jq -e '.result.status'")
    print("Test collection created successfully!")

    # ================================================================
    # Test 5: Insert and retrieve vectors (verify on-disk storage works)
    # ================================================================
    print("Inserting test vectors...")
    insert_result = machine.succeed("""
      curl -sf -X PUT http://127.0.0.1:6333/collections/test_collection/points \
        -H 'Content-Type: application/json' \
        -d '{"points": [{"id": 1, "vector": [0.1, 0.2, 0.3, 0.4], "payload": {"test": "data"}}]}'
    """)
    print(f"Insert result: {insert_result}")

    # Search for the vector
    print("Searching for vectors...")
    search_result = machine.succeed("""
      curl -sf -X POST http://127.0.0.1:6333/collections/test_collection/points/search \
        -H 'Content-Type: application/json' \
        -d '{"vector": [0.1, 0.2, 0.3, 0.4], "limit": 1}'
    """)
    print(f"Search result: {search_result}")

    # Verify we got the expected result
    machine.succeed("""
      curl -sf -X POST http://127.0.0.1:6333/collections/test_collection/points/search \
        -H 'Content-Type: application/json' \
        -d '{"vector": [0.1, 0.2, 0.3, 0.4], "limit": 1}' | jq -e '.result[0].id == 1'
    """)
    print("Vector search works correctly!")

    # ================================================================
    # Test 6: Memory usage check (critical for RPi5)
    # ================================================================
    print("Checking Qdrant memory usage...")
    # Get Qdrant RSS memory in KB
    mem_output = machine.succeed("ps -o rss= -p $(systemctl show --property MainPID --value qdrant.service)")
    mem_kb = int(mem_output.strip())
    mem_mb = mem_kb / 1024
    print(f"Qdrant memory usage: {mem_mb:.1f} MB")

    # Should use less than 500MB on idle with on_disk mode
    assert mem_mb < 500, f"Qdrant using too much memory: {mem_mb:.1f} MB (limit: 500 MB)"
    print("Memory usage within acceptable limits!")

    # ================================================================
    # Test 7: Cleanup - delete test collection
    # ================================================================
    print("Cleaning up test collection...")
    machine.succeed("curl -sf -X DELETE http://127.0.0.1:6333/collections/test_collection")
    print("Test collection deleted!")

    print("=" * 60)
    print("All Qdrant integration tests passed!")
    print("=" * 60)
  '';
}
