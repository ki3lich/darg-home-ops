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
end

if set -q _flag_help
    echo "Synchronizes the current Git repository with $remote_repo_url,"
    echo "and applies project-specific string replacements."
    echo ""
    echo "Usage: "(basename (status --current-filename))" [--clean] [--help]"
    echo ""
    echo "Options:"
    echo "  --clean    Remove all files and directories from the repository root"
    echo "             (except .git, this script, and temporary directories)"
    echo "             before copying files from the remote repository."
    echo "  -h, --help Show this help message and exit."
    exit 0
end

# --- Helper Functions ---

# Function to clean the current repository's working directory
function clean_current_repo_contents
    echo "Cleaning current repository contents (excluding .git, this script, and temp dirs)..."

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
        # Skip the temp clone directory if it's somehow in the CWD
        if test "$item_absolute_path" = (realpath "$temp_clone_dir")
            continue
        end

        echo "Removing $item_path"
        rm -rf "$item_path"
    end
end

# Function to perform string replacements in files
function perform_replacements_in_files
    echo "Performing replacements..."
    set target_dir "." # Current directory (should be git root)

    set -l replacements \
        onedr0p/home-ops ki3lich/darg-home-ops \
        devbu-io darg-win \
        "debbu\.io" "darg\.win" # Escaped dot for literal matching

    set -l files_to_process
    if command -v fd >/dev/null
        # Using fd: find files, hidden, no-ignore (respects .gitexclude but not .gitignore), exclude .git dir
        set files_to_process (fd --type f --hidden --no-ignore --exclude .git . "$target_dir")
    else
        echo "Warning: 'fd' command not found. Falling back to 'find'. This might be slower."
        set files_to_process (find "$target_dir" -type f -not -path '*/.git/*' -print)
    end

    for file_path in $files_to_process
        set -l is_text_file true # Assume text if 'file' command is missing or fails
        if command -v file >/dev/null
            set -l mime_type (file -b --mime-type "$file_path" 2>/dev/null)
            if test $status -ne 0 || not string match -qr "^text/" -- "$mime_type"
                set is_text_file false
                if test -n "$mime_type"
                    echo "Skipping binary/non-text file $file_path (MIME type: $mime_type)"
                else
                    echo "Skipping file $file_path (could not determine MIME type or not text)"
                end
            end
        else
            echo "Warning: 'file' command not found. Attempting replacements on $file_path without MIME type check."
        end

        if $is_text_file
            echo "Processing $file_path for replacements..."
            set -l temp_sed_file (mktemp)
            set -l original_content (cat "$file_path")
            set -l current_content $original_content

            for i in (seq 1 2 (count $replacements))
                set old_pattern $replacements[$i]
                set new_pattern $replacements[(math $i + 1)]
                set current_content (string replace -ra "$old_pattern" "$new_pattern" -- "$current_content")
            end

            # Only write if content changed to preserve timestamps and avoid unnecessary writes
            if test "$current_content" != "$original_content"
                echo "$current_content" >"$temp_sed_file"
                if test $status -eq 0
                    mv "$temp_sed_file" "$file_path"
                else
                    echo "Error: Failed to write changes to $file_path."
                    rm -f "$temp_sed_file"
                end
            else
                rm -f "$temp_sed_file" # No changes, remove temp file
            end
        end
    end
end

# Function to handle cleanup on exit
function cleanup_temp_dir --on-event fish_exit
    if test -d "$temp_clone_dir"
        echo "Cleaning up temporary directory $temp_clone_dir..."
        rm -rf "$temp_clone_dir"
    end
end

# --- Main Script Execution ---

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

# Copy files from the cloned repo to the current directory
echo "Synchronizing files from $temp_clone_dir to $git_root..."
if command -v rsync >/dev/null
    # Use rsync: archive mode, verbose, delete extraneous files, exclude .git from source
    rsync -a --delete --exclude='.git/' "$temp_clone_dir/" "./"
    if test $status -ne 0
        echo "Error: rsync command failed."
        exit 1
    end
else
    echo "Warning: 'rsync' command not found. Falling back to 'cp'."
    echo "This fallback will copy files but will NOT delete files from the destination"
    echo "that are not present in the source. For a clean sync, please install rsync."
    # Fallback to cp: copy recursively, force overwrite.
    # This won't handle deletions or all metadata like rsync.
    # Create a list of items to copy, excluding .git
    set items_to_copy
    for item in (ls -A $temp_clone_dir)
        if test "$item" != ".git"
            set -a items_to_copy "$item"
        end
    end
    if test (count $items_to_copy) -gt 0
        # Prepare paths for cp
        set cp_source_paths (for item in $items_to_copy; echo "$temp_clone_dir/$item"; end)
        cp -Rf $cp_source_paths ./
        if test $status -ne 0
            echo "Error: cp command failed."
            # Note: cp might have partially succeeded.
            exit 1
        end
    else
        echo "No items to copy from temporary clone directory."
    end
end

# Perform replacements
perform_replacements_in_files

echo ""
echo "Synchronization and replacement process complete."
echo "Please review the changes, then commit and push them if satisfied."

exit 0
