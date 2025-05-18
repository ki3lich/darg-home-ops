#!/usr/bin/env fish

# Script to synchronize this repository with a remote template repository
# and apply specific content replacements.

# --- Configuration ---
set -g remote_repo_url "https://github.com/onedr0p/home-ops.git"
set -g temp_clone_dir (mktemp -d)
set -g current_script_absolute_path (realpath (status --current-filename))

# --- Argument Parsing ---
argparse h/help c/clean -- $argv
or begin
    echo "Usage: "(basename (status --current-filename))" [--clean] [--help]"
    exit 1
    # LANG is not set here, so no need to restore original_locale
end

if set -q _flag_help
    echo "Synchronizes the current Git repository with $remote_repo_url,"
    echo "and applies project-specific string replacements."
    echo ""
    echo "Usage: "(basename (status --current-filename))" [--clean] [--help]"
    echo ""
    echo "Options:"
    echo "  --clean    Remove all files and directories from the repository root"
    echo "             (except .git, this script and its parent directories,"
    echo "             and temporary directories) before copying files from the"
    echo "             remote repository."
    echo "  -h, --help Show this help message and exit."
    exit 0
end

# --- Helper Functions ---

# Function to clean the current repository's working directory
function clean_current_repo_contents
    echo "Cleaning current repository contents (excluding .git, this script and its parents, and temp dirs)..."

    set items_in_cwd (ls -A) # List all items, including hidden

    for item in $items_in_cwd
        set item_path "./$item"
        set item_absolute_path (realpath "$item_path")

        # Skip .git directory
        if test "$item" = ".git"
            continue
        end
        # Skip the script itself
        if test "$item_absolute_path" = "$current_script_absolute_path"
            continue
        end
        # Skip any parent directory of the script
        if string starts-with -- "$current_script_absolute_path" "$item_absolute_path/"
            echo "Skipping $item_path as it contains the running script."
            continue
        end
        # Skip the temp clone directory if it's somehow in the CWD
        if test -d "$temp_clone_dir" && test "$item_absolute_path" = (realpath "$temp_clone_dir")
            continue
        end

        echo "Removing $item_path"
        rm -rf "$item_path"
    end
end

# Function to handle cleanup on exit
function cleanup_temp_dir --on-event fish_exit
    if test -d "$temp_clone_dir"
        echo "Cleaning up temporary directory $temp_clone_dir..."
        rm -rf "$temp_clone_dir"
    end
end

# Function to perform replacements in files
function perform_replacements_in_files
    set files_to_modify (find . -type f)

    set -l original_locale $LANG
    set LANG C
    for file_relative_path in $files_to_modify
        set file_absolute_path ""
        # Try to get the absolute path; handle potential errors if realpath fails
        if set -l resolved_path (realpath "$file_relative_path" 2>/dev/null)
            set file_absolute_path $resolved_path
        else
            echo "Warning: Could not resolve path for $file_relative_path. Skipping."
            continue
        end

        # Skip if the file is the script itself
        if test "$file_absolute_path" = "$current_script_absolute_path"
            echo "Skipping replacement in the script itself: $file_relative_path"
            continue
        end

        # Check if it's a regular file before attempting sed
        if test -f "$file_relative_path"
            sed -i '' -e 's/onedr0p\/home-ops/ki3lich\/darg-home-ops/g' \
                -e s/onedr0p/ki3lich/g \
                -e s/devbu-io/darg-win/g \
                -e 's/copyMethod:\ Snapshot/copyMethod:\ Direct/g' \
                -e 's/=Snapshot/=Direct/g' \
                -e 's/devbu\.io/darg\.win/g' \
                -e s/VOLSYNC_CACHE_SNAPSHOTCLASS/VOLSYNC_CACHE_STORAGECLASS//g \
                -e 's/op:\/\/kubernetes/op:\/\/darg-home-ops/g' \
                -e 's/192\.168\.42\.120/192.168.1.203/g' \
                -e 's/192\.168\.42\.0/192.168.1./g' \
                -e s/ceph-block/openebs-hostpath/g "$file_relative_path" \
                -e s/csi-//g
        else
            echo "Warning: $file_relative_path is not a regular file or was removed. Skipping sed."
        end
    end
    set LANG $original_locale # Restore original locale
end

# Navigate to Git repository root
set git_root (git rev-parse --show-toplevel)
if test $status -ne 0
    echo "Error: This script must be run from within a Git repository."
    exit 1
end
cd "$git_root"
echo "Operating in repository root: $git_root"

# Optional: Clean the repository working directory
if set -q _flag_clean
    clean_current_repo_contents
end

# Clone the remote repository
echo "Cloning $remote_repo_url into $temp_clone_dir..."
if not git clone --depth 1 "$remote_repo_url" "$temp_clone_dir"
    echo "Error: Failed to clone repository from $remote_repo_url."
    exit 1
end

# Determine script path relative to git root for exclusion
set script_relative_path_to_git_root (python3 -c "import os; print(os.path.relpath('$current_script_absolute_path', '$git_root'))")

# Copy files from the cloned repo to the current directory
echo "Synchronizing files from $temp_clone_dir to $git_root..."
if command -v rsync >/dev/null
    set rsync_excludes_list \
        "$script_relative_path_to_git_root" \
        ".github/CODE_OF_CONDUCT.md" \
        ".vscode/" \
        "talos/nodes/*" \
        ".sops.yaml" \
        LICENSE \
        "README.md"

    set rsync_args
    set -a rsync_args -a --delete "--exclude=.git/"
    for ex_item in $rsync_excludes_list
        set -a rsync_args "--exclude=$ex_item"
    end
    set -a rsync_args "$temp_clone_dir/" "./"

    rsync $rsync_args
    if test $status -ne 0
        echo "Error: rsync command failed."
        # Consider exiting if rsync fails, as subsequent steps might operate on incorrect/incomplete data
        # exit 1; # Uncomment if strict failure is desired
    end
else
    echo "Warning: 'rsync' command not found. Falling back to 'cp'."
    echo "This fallback will copy files but will NOT delete files from the destination"
    echo "that are not present in the source, and file exclusion capabilities are limited."
    echo "Only some top-level files/directories specified for exclusion might be skipped."
    echo "Nested exclusions (e.g. '.github/CODE_OF_CONDUCT.md', 'talos/nodes/*') will not be applied."
    echo "For a clean and precise sync, please install rsync."

    set script_top_level_item (string split -m1 / $script_relative_path_to_git_root)[1]
    set general_root_exclusions ".vscode" ".sops.yaml" LICENSE "README.md"

    set items_to_copy_sources
    for item_name in (ls -A $temp_clone_dir)
        if test "$item_name" = ".git"
            continue
        end
        if test "$item_name" = "$script_top_level_item"
            continue
        end

        set -l skip_general_exclusion = false
        for exclusion in $general_root_exclusions
            if test "$item_name" = "$exclusion"
                set skip_general_exclusion true
                break
            end
        end
        if $skip_general_exclusion
            continue
        end

        set -a items_to_copy_sources "$temp_clone_dir/$item_name"
    end

    if test (count $items_to_copy_sources) -gt 0
        cp -Rf $items_to_copy_sources ./
        if test $status -ne 0
            echo "Error: cp command failed."
            # exit 1; # Uncomment if strict failure is desired
        end
    else
        echo "No items to copy from temporary clone directory (after exclusions)."
    end
end

# Perform replacements
perform_replacements_in_files

echo ""
echo "Synchronization and replacement process complete."
echo "Please review the changes, then commit and push them if satisfied."

exit 0
