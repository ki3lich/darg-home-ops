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

# Function to perform string replacements in files
function perform_replacements_in_files
    # Helper function to escape the chosen delimiter for sed's pattern part (LHS of s///)
    # Assumes pattern_str is already a valid regex.
    function escape_sed_pattern_delimiter --argument pattern_str --argument delimiter
        string replace -a "$delimiter" "\\$delimiter" -- "$pattern_str"
    end

    # Helper function to escape special characters for sed's replacement part (RHS of s///)
    # This includes the delimiter, '&' (backreference), and '\' (escape character).
    function escape_sed_replacement_chars --argument replacement_str --argument delimiter
        string replace -a '\' '\\\\' -- "$replacement_str" |
            string replace -a '&' '\&' |
            string replace -a "$delimiter" "\\$delimiter"
    end

    echo "Performing replacements using sed..."
    set target_dir "." # Current directory (should be git root)
    set -l sed_delimiter '#' # Using # as sed delimiter to handle paths with /

    set -l replacements \
        onedr0p/home-ops ki3lich/darg-home-ops \
        devbu-io darg-win \
        "debbu\.io" "darg\.win" \
        "op://kubernetes" "op://darg-home-ops" \
        "192\.168\.42\.120" "192.168.1.203" \
        "192\.168\.42\.0" "192.168.1." \
        "ceph-block" "openebs-hostpath"

    set -l files_to_process
    if command -v fd >/dev/null
        set files_to_process (fd --type f --hidden --no-ignore --exclude .git . "$target_dir")
    else
        echo "Warning: 'fd' command not found. Falling back to 'find'. This might be slower."
        set files_to_process (find "$target_dir" -type f -not -path '*/.git/*' -print)
    end

    for file_path in $files_to_process
        set -l is_text_file true
        if command -v file >/dev/null
            set -l mime_type (file -b --mime-type "$file_path" 2>/dev/null)
            if test $status -ne 0 || not string match -qr "^text/" -- "$mime_type"
                set is_text_file false
                if test -n "$mime_type" && test "$mime_type" != "application/octet-stream" # common for empty or unknown
                    echo "Skipping binary/non-text file $file_path (MIME type: $mime_type)"
                else if test -z "$mime_type"
                    echo "Skipping file $file_path (could not determine MIME type or not text)"
                # else, octet-stream or empty, might be text, try anyway or refine check
                end
            end
        else
            echo "Warning: 'file' command not found. Attempting replacements on $file_path without MIME type check."
        end

        if $is_text_file
            set -l temp_sed_commands_file ""
            set -l needs_sed_run false

            for i in (seq 1 2 (count $replacements))
                set old_pattern $replacements[$i]
                set new_pattern $replacements[(math $i + 1)]

                # Check if the pattern (as a regex for grep) exists in the file
                if grep -q -- "$old_pattern" "$file_path"
                    if not $needs_sed_run # Create temp file only if we haven't already for this file_path
                        set temp_sed_commands_file (mktemp)
                    end
                    set needs_sed_run true
                    set escaped_old (escape_sed_pattern_delimiter "$old_pattern" "$sed_delimiter")
                    set escaped_new (escape_sed_replacement_chars "$new_pattern" "$sed_delimiter")
                    # Append sed command to the temporary command file
                    echo "s$sed_delimiter$escaped_old$sed_delimiter$escaped_new$sed_delimiter""g" >> "$temp_sed_commands_file"
            end

            if $needs_sed_run
                echo "Applying sed commands to $file_path"
                set temp_output_file (mktemp)
                if sed -f "$temp_sed_commands_file" "$file_path" > "$temp_output_file"
                    # Compare original with sed output; update only if different
                    if not cmp -s "$file_path" "$temp_output_file"
                        echo "Content changed, updating $file_path"
                        if mv "$temp_output_file" "$file_path"
                            # Successfully moved temp_output_file to file_path
                        else
                            echo "Error: Failed to move temp output file to $file_path."
                            rm -f "$temp_output_file" # Clean up temp output if mv failed
                        end
                    else
                        echo "Content unchanged by sed for $file_path, skipping update."
                        rm -f "$temp_output_file" # Clean up temp output, no changes needed
                    end
                else
                    echo "Error: sed command failed for $file_path."
                    rm -f "$temp_output_file" # Clean up temp output if sed failed
                end
            else
                echo "No relevant patterns found by grep in $file_path, skipping sed."
            end

            if test -n "$temp_sed_commands_file" && test -f "$temp_sed_commands_file"
                rm -f "$temp_sed_commands_file" # Clean up sed command file
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

# Determine script path relative to git root for exclusion
set script_relative_path_to_git_root (realpath --relative-to="$git_root" "$current_script_absolute_path")

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
