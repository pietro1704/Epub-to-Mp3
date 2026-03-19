#!/usr/bin/env python3
"""Display auto-tuning configuration.

Usage:
    python show_autotuning.py              # Show current config
    python show_autotuning.py --measure    # Also measure network speed
"""

import argparse
import asyncio

from python_app.src.auto_tuner import AutoTuner


async def main():
    parser = argparse.ArgumentParser(description="Display auto-tuning configuration")
    parser.add_argument(
        "--measure",
        action="store_true",
        help="Measure network speed (adds ~3s)",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply configuration to the environment",
    )
    args = parser.parse_args()

    tuner = AutoTuner(verbose=True)

    # Auto-configure
    profile = await tuner.auto_configure(
        force=args.apply,
        measure_network=args.measure,
    )

    print("\n" + "=" * 70)
    print("💡 RECOMMENDATIONS")
    print("=" * 70)

    if profile.name == "Conservative":
        print("🐌 Conservative profile detected.")
        print("   • Consider improving your internet connection")
        print("   • Or increasing available RAM")
        print("   • Conversions will be slower but stable")
    elif profile.name == "Balanced":
        print("⚖️  Balanced profile detected.")
        print("   • Good balance between speed and stability")
        print("   • To improve: upgrade internet or RAM")
    elif profile.name == "Performance":
        print("🚀 Performance profile detected!")
        print("   • Good setup for fast conversions")
        print("   • System is optimized")
    else:  # Maximum
        print("⚡ Maximum profile detected!")
        print("   • Ideal setup for ultra-fast conversions")
        print("   • Enjoy the speed!")

    print("\n💾 To disable auto-tuning:")
    print("   export ENABLE_AUTO_TUNING=0")
    print("\n🔧 To force a specific profile, set manually:")
    print("   export EDGE_MAX_CONCURRENCY=8")
    print("   export EDGE_CHUNK_CHARS=10000")
    print("=" * 70 + "\n")


if __name__ == "__main__":
    asyncio.run(main())
