using System.Security;
using BurrowWin.Models;
using Microsoft.VisualBasic.FileIO;

namespace BurrowWin.Services;

public sealed class RecycleBinDeletionService : ISafeDeletionService
{
    public LeftoverRemovalResult DeleteFileOrDirectory(string path, long sizeBytes)
    {
        try
        {
            var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));
            if (Directory.Exists(fullPath))
            {
                FileSystem.DeleteDirectory(
                    fullPath,
                    UIOption.OnlyErrorDialogs,
                    RecycleOption.SendToRecycleBin,
                    UICancelOption.ThrowException);
                return new LeftoverRemovalResult(path, true, "Directory moved to Recycle Bin.", sizeBytes);
            }

            if (File.Exists(fullPath))
            {
                FileSystem.DeleteFile(
                    fullPath,
                    UIOption.OnlyErrorDialogs,
                    RecycleOption.SendToRecycleBin,
                    UICancelOption.ThrowException);
                return new LeftoverRemovalResult(path, true, "File moved to Recycle Bin.", sizeBytes);
            }

            return new LeftoverRemovalResult(path, true, "Path was already absent.", sizeBytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SecurityException or OperationCanceledException or ArgumentException or NotSupportedException)
        {
            return new LeftoverRemovalResult(path, false, ex.Message, sizeBytes);
        }
    }
}
