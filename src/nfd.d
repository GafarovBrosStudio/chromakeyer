module nfd;

extern(C):

struct nfdpathset_t
{
    char* buf;
    size_t* indices;
    size_t count;
}

enum
{
    NFD_ERROR,
    NFD_OKAY,
    NFD_CANCEL
}

int NFD_OpenDialog(in char* filterList, in char* defaultPath, char** outPath); 
int NFD_OpenDialogMultiple(in char* filterList, in char* defaultPath, nfdpathset_t* outPaths);
int NFD_SaveDialog(in char* filterList, in char* defaultPath, char** outPath);
int NFD_PickFolder(in char* defaultPath, char** outPath);

const(char*) NFD_GetError();
size_t NFD_PathSet_GetCount(in nfdpathset_t* pathSet);
char* NFD_PathSet_GetPath(in nfdpathset_t* pathSet, size_t index);
void NFD_PathSet_Free(nfdpathset_t* pathSet);