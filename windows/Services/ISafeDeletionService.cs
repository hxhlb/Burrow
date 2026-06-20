using BurrowWin.Models;

namespace BurrowWin.Services;

public interface ISafeDeletionService
{
    LeftoverRemovalResult DeleteFileOrDirectory(string path, long sizeBytes);
}
