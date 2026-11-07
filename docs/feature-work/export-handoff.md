# Copy and drag exported clips

Read [shared execution rules](README.md) before implementation. Work only on this feature in its assigned T3 worktree.

After a successful export, make it easy to copy the actual exported file and drag it directly into apps that accept file drops. A compact thumbnail/file affordance with a Copy action should avoid the Finder detour and fit the existing restrained glass footer. Preserve Show in Finder access.

Use a real file URL/file representation, not just a copied path string. The file must survive managed URL-import cleanup. Handle repeated exports/replacements and files moved or removed outside the app without stale or broken actions. A native share picker is optional only if it improves the small UI; copy and drag are the required feature.

Acceptance: file-copy pasteboard representation, drag provider and exported-file lifecycle are checked. Use an isolated named pasteboard for automated tests rather than modifying the user's general clipboard. Provide a runnable review build and short manual test instructions for receiving apps.

