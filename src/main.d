module main;

import std.stdio;
import std.math;
import std.path;
import std.conv;
import std.string;
import std.format;
import std.file;

import dagon;
import nfd;
import props;

enum CKVersionMajor = 1;
enum CKVersionMinor = 0;
enum CKVersionPatch = 0;

uint NumUndoLevels = 4;
float ChromaKeyMinDistance = 0.1f;
float ChromaKeyMaxDistance = 0.2f;

Vector3f yiq(Color4f c)
{
    float y = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
    float i = 0.596 * c.r - 0.274 * c.g - 0.322 * c.b;
    float q = 0.211 * c.r - 0.522 * c.g + 0.311 * c.b;
    return Vector3f(y, i, q);
}

SuperImage chromaKeyEuclideanYIQ(
    SuperImage img,
    SuperImage outp,
    Color4f backgroundColor,
    float minDist,
    float maxDist)
{
    SuperImage res;
    if (outp)
        res = outp;
    else
        res = img.dup;

    enum ky = 0.5f;
    enum ki = 1.4f;
    enum kq = 0.6f;

    foreach(y; img.col)
    foreach(x; img.row)
    {
        Color4f col = img[x, y];

        if (col.a > 0.001f)
        {
            Vector3f input = yiq(col);
            Vector3f key = yiq(backgroundColor);

            Vector3f delta = input - key;

            float distSqr = sqrt(ky * (delta.x * delta.x) + ki * (delta.y * delta.y) + kq * (delta.z * delta.z));

            float a = clamp(
                (distSqr - minDist) / (maxDist - minDist),
                0.0f, 1.0f);

            col.a = col.a * a;
        }
        res[x, y] = col;
    }

    return res;
}

SuperImage erodeAlpha(SuperImage img, SuperImage outp)
{
    SuperImage res;
    if (outp)
        res = outp;
    else
        res = img.dup;

    uint kw = 3, kh = 3;
    foreach(y; img.col)
    foreach(x; img.row)
    {
        auto c = img[x, y];
        foreach(ky; 0..kh)
        foreach(kx; 0..kw)
        {
            int iy = y + (ky - kh/2);
            int ix = x + (kx - kw/2);
            if  (ix < 0) ix = 0;
            if  (ix >= img.width) ix = img.width - 1;
            if  (iy < 0) iy = 0;
            if  (iy >= img.height) iy = img.height - 1;
            float a = img[ix, iy].a;
            if (a < c.a)
                c.a = a;
        }
        res[x, y] = c;
    }
    return res;
}

float clampf(float x, float mi, float ma)
{
    if (x < mi) return mi;
    else if (x > ma) return ma;
    else return x;
}

float minf(float a, float b)
{
    if (a < b) return a;
    else return b;
}

enum PaintMode
{
    AlphaOver,
    Erase,
    AntiErase,
    Shadows,
    Desaturate,
}

class KeyFrame: Owner
{
    ulong number;
    double duration;
    SuperImage image;
    SuperImage[] history; // history[0] stores next level from image
    Texture texture;

    this(uint w, uint h, Owner o)
    {
        super(o);
        number = 0;
        duration = 0.0;

        image = New!UnmanagedImageRGBA8(w, h);
        image.fillColor(Color4f(0.0f, 0.0f, 0.0f, 0.0f));
        
        history = New!(SuperImage[])(NumUndoLevels);
        
        foreach(i; 0..NumUndoLevels)
        {
            history[i] = New!UnmanagedImageRGBA8(w, h);
            history[i].fillColor(Color4f(0.0f, 0.0f, 0.0f, 0.0f));
        }
        texture = New!Texture(image, this, false);
    }

    void recreate(uint w, uint h)
    {
        Delete(image);

        image = New!UnmanagedImageRGBA8(w, h);
        image.fillColor(Color4f(0.0f, 0.0f, 0.0f, 0.0f));

        foreach(i; 0..NumUndoLevels)
        {
            Delete(history[i]);
            history[i] = New!UnmanagedImageRGBA8(w, h);
            history[i].fillColor(Color4f(0.0f, 0.0f, 0.0f, 0.0f));
        }

        texture.release();
        texture.createFromImage(image, false, false);
    }
    
    void backup()
    {
        for (uint i = NumUndoLevels-1; i > 0; i--)
        {
            history[i].data[] = history[i-1].data[];
        }
        
        history[0].data[] = image.data[];
    }
    
    void restore()
    {
        image.data[] = history[0].data[];
        
        foreach(i; 0..NumUndoLevels-1)
        {
            history[i].data[] = history[i+1].data[];
        }
    }

    ~this()
    {
        Delete(image);
        
        foreach(i; 0..NumUndoLevels)
        {
            Delete(history[i]);
        }
        
        Delete(history);
    }

    void blitImageCentered(SuperImage img)
    {
        int startx = image.width/2 - img.width/2;
        int starty = image.height/2 - img.height/2;
        foreach(y; 0..img.height)
        foreach(x; 0..img.width)
        {
            int xx = startx + x;
            int yy = starty + y;
            if (yy >= 0 && xx >= 0 && yy < image.height && xx < image.width)
            {
                Color4f c1 = image[xx, yy];
                Color4f c2 = img[x, y];
                image[xx, yy] = alphaOver(c1, c2);
            }
        }

        texture.updateFromImage(image);
        
        foreach(i; 0..NumUndoLevels)
        {
            history[i].data[] = image.data[];
        }
    }
}

class Painter: Owner
{
    float zoom;
    Vector2f position;
    Vector2f pan;
    KeyFrame frame;

    Texture backgroundTexture;

    this(Vector2f pos, Owner o)
    {
        super(o);
        zoom = 1.0f;
        pan = Vector2f(0.0f, 0.0f);
        position = pos;
    }

    void backup()
    {
        if (frame is null) return;

        frame.backup();
    }

    void restore()
    {
        if (frame is null) return;

        frame.restore();
        frame.texture.updateFromImage(frame.image);
    }

    void chromaKey(Color4f keyColor)
    {
        if (frame is null) return;

        auto outp = frame.image.dup;
        chromaKeyEuclideanYIQ(frame.image, outp, keyColor, ChromaKeyMinDistance, ChromaKeyMaxDistance);
        frame.image.data[] = outp.data[];
        frame.texture.updateFromImage(frame.image);
        Delete(outp);
    }

    void erodeAlpha()
    {
        if (frame is null) return;

        auto outp = frame.image.dup;
        .erodeAlpha(frame.image, outp);
        frame.image.data[] = outp.data[];
        frame.texture.updateFromImage(frame.image);
        Delete(outp);
    }

    void paintLine(SuperImage brush, Vector2f start, Vector2f end, PaintMode mode)
    {
        if (frame is null) return;

        uint maxSteps = cast(uint)clampf(distance(start, end) * 0.5f, 1.0f, 30.0f);
        float stepSize = 1.0f / maxSteps;
        for(uint i = 0; i < maxSteps; i++)
        {
            float t = i * stepSize;
            paint(brush, lerp(start, end, t), mode);
        }
    }

    void paint(SuperImage brush, Vector2f b, PaintMode mode)
    {
        if (frame is null) return;

        b = windowSpaceToImageSpace(b);

        int startx = cast(int)b.x - brush.width/2;
        int starty = cast(int)b.y - brush.height/2;
        foreach(y; 0..brush.height)
        foreach(x; 0..brush.width)
        {
            int xx = startx + x;
            int yy = starty + y;
            if (yy >= 0 && xx >= 0 && yy < frame.image.height && xx < frame.image.width)
            {
                Color4f c1 = frame.image[xx, yy];
                Color4f c2 = brush[x, y];
                if (mode == PaintMode.AlphaOver)
                    frame.image[xx, yy] = alphaOver(c1, c2);
                else if (mode == PaintMode.Erase)
                    frame.image[xx, yy] = Color4f(c1.r, c1.g, c1.b, c1.a - c2.a);
                else if (mode == PaintMode.AntiErase)
                    frame.image[xx, yy] = Color4f(c1.r, c1.g, c1.b, c1.a + c2.a);
                else if (mode == PaintMode.Shadows)
                    frame.image[xx, yy] = lerp(c1, Color4f(0.0f, 0.0f, 0.0f, minf(c1.a, 0.5)), c2.a);
                else if (mode == PaintMode.Desaturate)
                {
                    float luma = c1.luminance;
                    frame.image[xx, yy] = lerp(c1, Color4f(luma, luma, luma, c1.a), c2.a);
                }
            }
        }
    }

    Color4f getColor(Vector2f b)
    {
        if (frame is null) return Color4f(1,1,1,1);
        b = windowSpaceToImageSpace(b);
        return frame.image[cast(int)b.x, cast(int)b.y];
    }

    void updateFrame()
    {
        if (frame is null) return;
        frame.texture.updateFromImage(frame.image);
    }

    Vector2f windowSpaceToImageSpace(Vector2f m)
    {
        if (frame is null) return m;

        m -= position + pan;
        m /= zoom;
        m += Vector2f(frame.image.width * 0.5f, frame.image.height * 0.5f);
        m.y = frame.image.height - m.y;
        return m;
    }

    void render()
    {
        glPushMatrix();
        glTranslatef(position.x, position.y, 0.0f);
        glTranslatef(pan.x, pan.y, 0.0f);
        if (frame !is null)
            glScalef(frame.image.width * zoom, frame.image.height * zoom, 1.0f);
        else
            glScalef(100.0f, 100.0f, 1.0f);
        Color4f(1.0f, 1.0f, 1.0f, 1.0f);

        if (backgroundTexture)
            backgroundTexture.bind();
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        if (backgroundTexture)
            backgroundTexture.unbind();

        if (frame !is null)
            frame.texture.bind();
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        if (frame !is null)
            frame.texture.unbind();

        glPopMatrix();
    }
}

class SMApplication: Application
{
    Properties settings;

    StdFileSystem fs;
    UnmanagedImageFactory imageFactory;

    ubyte[] fontBuffer;
    FreeTypeFont font;

    SuperImage brush;

    TextLine textImageFilename;
    TextLine textFilename;
    TextLine textHint;

    DynamicArray!string currentDirFiles;
    bool notLMBPressed = true;

    KeyFrame frame;
    Painter painter;
    Matrix4x4f projectionMatrix;

    bool beginPanning = true;
    Vector2f panStart;
    Vector2f panMouseStart;

    bool haveOldPos = false;
    Vector2f oldPos;

    bool fileSelectionMode = false;
    Vector2f dialogPos;

    PaintMode currentMode = PaintMode.AntiErase;
    bool colorSelectionMode = false;
    bool shadowsMode = false;

    Texture eraserTexture;
    Texture chromakeyTexture;
    Texture erodeTexture;
    Texture undoTexture;
    Texture openTexture;
    Texture saveTexture;
    Texture shadowsTexture;
    Texture desaturateTexture;

    float buttonHSize = 32.0f;
    
    Vector2f eraserButtonPos = Vector2f(32.0f, 32.0f);
    bool eraserButtonPressed = false;

    Vector2f chromakeyButtonPos = Vector2f(32.0f + 64.0f, 32.0f);
    bool chromakeyButtonPressed = false;

    Vector2f erodeButtonPos = Vector2f(32.0f + 64.0f + 64.0f, 32.0f);
    bool erodeButtonPressed = false;

    Vector2f shadowButtonPos = Vector2f(32.0f + 64.0f + 64.0f + 64.0f, 32.0f);
    bool shadowButtonPressed = false;
    
    Vector2f desaturateButtonPos = Vector2f(32.0f + 64.0f + 64.0f + 64.0f + 64.0f, 32.0f);
    bool desaturateButtonPressed = false;

    Vector2f undoButtonPos = Vector2f(32.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f, 32.0f);
    bool undoButtonPressed = false;
    
    Vector2f openButtonPos = Vector2f(32.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f, 32.0f);
    bool openButtonPressed = false;
    
    Vector2f saveButtonPos = Vector2f(32.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f + 64.0f, 32.0f);
    bool saveButtonPressed = false;
    
    SDL_Cursor* cursorArrow;
    SDL_Cursor* cursorPan;
    SDL_Cursor* cursorCross;
    SDL_Cursor* cursorWait;
    
    bool showHint = false;
    string hint;
    Vector2f hintPos = Vector2f(0, 0);

    this(uint w, uint h, string windowTitle, string[] args, Properties settings)
    {
        super(w, h, windowTitle, args);
        
        this.settings = settings;

        fs = New!StdFileSystem();
        imageFactory = New!UnmanagedImageFactory();

        font = New!FreeTypeFont(12);
        auto fstrm = fs.openForInput("data/fonts/DroidSans.ttf");
        FileStat s;
        fs.stat("data/fonts/DroidSans.ttf", s);
        fontBuffer = New!(ubyte[])(cast(size_t)s.sizeInBytes);
        fstrm.fillArray(fontBuffer);
        font.createFromMemory(fontBuffer);
        Delete(fstrm);

        frame = New!KeyFrame(100, 100, this);

        painter = New!Painter(Vector2f(eventManager.windowWidth * 0.5f, eventManager.windowHeight * 0.5f), this);
        painter.frame = frame;

        brush = loadImage("data/brushes/brush16.png");

        projectionMatrix = orthoMatrix(0.0f, w, 0.0f, h, 0.0f, 100.0f);

        glClearColor(0.25f, 0.25f, 0.25f, 1.0f);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_DEPTH_TEST);
        glDepthMask(GL_FALSE);

        auto eraserImage = loadImage("data/icons/eraser.png");
        eraserTexture = New!Texture(eraserImage, this, false, true);
        Delete(eraserImage);

        auto chromakeyImage = loadImage("data/icons/chromakey.png");
        chromakeyTexture = New!Texture(chromakeyImage, this, false, true);
        Delete(chromakeyImage);

        auto erodeImage = loadImage("data/icons/erode.png");
        erodeTexture = New!Texture(erodeImage, this, false, true);
        Delete(erodeImage);

        auto undoImage = loadImage("data/icons/undo.png");
        undoTexture = New!Texture(undoImage, this, false, true);
        Delete(undoImage);
        
        auto openImage = loadImage("data/icons/open.png");
        openTexture = New!Texture(openImage, this, false, true);
        Delete(openImage);

        auto saveImage = loadImage("data/icons/save.png");
        saveTexture = New!Texture(saveImage, this, false, true);
        Delete(saveImage);
        
        auto glassesImage = loadImage("data/icons/glasses.png");
        shadowsTexture = New!Texture(glassesImage, this, false, true);
        Delete(glassesImage);
       
        auto desaturateImage = loadImage("data/icons/desaturate.png");
        desaturateTexture = New!Texture(desaturateImage, this, false, true);
        Delete(desaturateImage);

        auto checkerImage = loadImage("data/icons/checkerboard.png");
        painter.backgroundTexture = New!Texture(checkerImage, this, false, false);
        painter.backgroundTexture.scale = Vector2f(frame.image.width / 64.0f, frame.image.height / 64.0f);
        Delete(checkerImage);

        textImageFilename = New!TextLine(font, "Please, open an image (or drag and drop it to application window)", this);
        textImageFilename.color = Color4f(1.0f, 1.0f, 1.0f, 1.0f);
        
        textHint = New!TextLine(font, "", this);
        textHint.color = Color4f(1.0f, 1.0f, 1.0f, 1.0f);
        
        cursorArrow = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_ARROW);
        cursorPan = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_SIZEALL);
        cursorCross = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_CROSSHAIR);
        cursorWait = SDL_CreateSystemCursor(SDL_SYSTEM_CURSOR_WAIT);
        SDL_SetCursor(cursorArrow);
        
        openButtonPos = Vector2f(w - 32.0f - 64.0f, 32.0f);
        saveButtonPos = Vector2f(w - 32.0f, 32.0f);
    }
    
    override void onDropFile(string filename)
    {
        writeln(filename);
        
        if (isImageFile(filename))
        {
            auto img = loadImage(filename);
            if (img)
            {
                textImageFilename.color = Color4f(1.0, 1.0, 1.0, 1.0);
                textImageFilename.setText(filename);
                frame.recreate(img.width, img.height);
                frame.blitImageCentered(img);
                Delete(img);
            }
            else
            {
                textImageFilename.color = Color4f(1.0, 0.5, 0.5, 1.0);
                textImageFilename.setText(format("Error opening \"%s\", look the console for details", filename));
            }
        }
    }

    ~this()
    {
        Delete(fs);
        Delete(imageFactory);

        Delete(brush);

        Delete(font);
        Delete(fontBuffer);

        currentDirFiles.free();
    }
    
    bool isImageFile(string filename)
    {
        switch(filename.extension)
        {
            case ".bmp", ".BMP": return true;
            case ".jpg", ".JPG", ".jpeg", ".JPEG": return true;
            case ".png", ".PNG": return true;
            case ".tga", ".TGA": return true;
            default:
                return false;
        }
    }

    SuperImage loadImage(string filename)
    {
        auto fstrm = fs.openForInput(filename);
        Compound!(SuperImage, string) res;
        switch(filename.extension)
        {
            case ".bmp", ".BMP":
                res = loadBMP(fstrm, imageFactory);
                break;
            case ".jpg", ".JPG", ".jpeg", ".JPEG":
                res = loadJPEG(fstrm, imageFactory);
                break;
            case ".png", ".PNG":
                res = loadPNG(fstrm, imageFactory);
                break;
            case ".tga", ".TGA":
                res = loadTGA(fstrm, imageFactory);
                break;
            default:
                break;
        }
        Delete(fstrm);
        if (res[0] is null)
            writeln(res[1]);
        return res[0];
    }

    void saveImage(SuperImage img, string filename)
    {
        auto fstrm = fs.openForOutput(filename);
        savePNG(img, fstrm);
        Delete(fstrm);
    }

    override void onResize(int width, int height)
    {
        super.onResize(width, height);
        projectionMatrix = orthoMatrix(0.0f, width, 0.0f, height, 0.0f, 100.0f);
        painter.position = Vector2f(eventManager.windowWidth * 0.5f, eventManager.windowHeight * 0.5f);
        
        openButtonPos = Vector2f(width - 32.0f - 64.0f, 32.0f);
        saveButtonPos = Vector2f(width - 32.0f, 32.0f);
    }

    override void onMouseWheel(int x, int y)
    {
        painter.zoom += cast(float)y * 0.05f;
    }
    
    void openImageDialog()
    {
        char* outPath = null;
        auto result = NFD_OpenDialog("png,jpg,bmp,tga", null, &outPath);
        if (result == NFD_OKAY)
        {
            string p = to!string(outPath);
            SDL_SetCursor(cursorWait);
            onDropFile(p);
            SDL_SetCursor(cursorArrow);
        }
    }
    
    void saveImageDialog()
    {
        char* outPath = null;
        auto result = NFD_SaveDialog("png", null, &outPath);
        if (result == NFD_OKAY)
        {                
            string filename = to!string(outPath);
            if (extension(filename) == "")
                filename = filename ~ ".png";
            SDL_SetCursor(cursorWait);
            if (painter.frame)
            {
                saveImage(painter.frame.image, filename);
                textImageFilename.color = Color4f(1.0, 1.0, 1.0, 1.0);
                textImageFilename.setText(format("Image saved to \"%s\"", filename));
            }
            SDL_SetCursor(cursorArrow);
        }
    }

    override void onKeyDown(int key)
    {
        if (key == KEY_O && eventManager.keyPressed[KEY_LCTRL])
            openImageDialog();
        else if (key == KEY_S && eventManager.keyPressed[KEY_LCTRL])
            saveImageDialog();
        else if (key == KEY_Z && eventManager.keyPressed[KEY_LCTRL])
        {
            SDL_SetCursor(cursorWait);
            painter.restore();
            SDL_SetCursor(cursorArrow);
        }
    }

    override void onUpdate(double dt)
    {
        dialogPos = Vector2f(eventManager.windowWidth * 0.5f - 100.0f, eventManager.windowHeight * 0.5f + 200.0f);

        processDrawingModeInput();

        painter.backgroundTexture.scale = 
            Vector2f(frame.image.width * painter.zoom / 64.0f, frame.image.height * painter.zoom / 64.0f);
    }
    
    override void onMouseButtonDown(int button)
    {
        if (button == MB_MIDDLE)
            SDL_SetCursor(cursorPan);
    }
    
    override void onMouseButtonUp(int button)
    {
        if (colorSelectionMode)
            SDL_SetCursor(cursorCross);
        else
            SDL_SetCursor(cursorArrow);
    }

    void processDrawingModeInput()
    {
        if (eventManager.mouseButtonPressed[MB_MIDDLE])
        {
            if (beginPanning)
            {
                beginPanning = false;
                panStart = painter.pan;
                panMouseStart = Vector2f(eventManager.mouseX, eventManager.mouseY);
            }
            else
                painter.pan = panStart + Vector2f(eventManager.mouseX, eventManager.mouseY) - panMouseStart;
        }
        else
        {
            beginPanning = true;
        }

        if (eventManager.mouseButtonPressed[MB_LEFT])
        {
            if (colorSelectionMode && !chromakeyButtonPressed)
            {
                SDL_SetCursor(cursorWait);
                Vector2f m = Vector2f(eventManager.mouseX, eventManager.mouseY);
                Color4f col = painter.getColor(m);
                painter.backup();
                painter.chromaKey(col);
                colorSelectionMode = false;
                textImageFilename.setText("");
                SDL_SetCursor(cursorArrow);
            }
            else if (mouseInButton(eraserButtonPos, buttonHSize))
            {
                if (!eraserButtonPressed)
                {
                    eraserButtonPressed = true;
                    if (currentMode == PaintMode.AntiErase)
                        currentMode = PaintMode.Erase;
                    else
                        currentMode = PaintMode.AntiErase;
                }
            }
            else if (mouseInButton(chromakeyButtonPos, buttonHSize))
            {
                if (!chromakeyButtonPressed)
                {
                    chromakeyButtonPressed = true;
                    colorSelectionMode = true;
                    textImageFilename.color = Color4f(1.0, 1.0, 1.0, 1.0);
                    textImageFilename.setText("Pick a key color");
                }
            }
            else if (mouseInButton(erodeButtonPos, buttonHSize))
            {
                if (!erodeButtonPressed)
                {
                    erodeButtonPressed = true;
                    SDL_SetCursor(cursorWait);
                    painter.backup();
                    painter.erodeAlpha();
                    SDL_SetCursor(cursorArrow);
                }
            }
            else if (mouseInButton(shadowButtonPos, buttonHSize))
            {
                if (!shadowButtonPressed)
                {
                    shadowButtonPressed = true;
                    if (currentMode == PaintMode.Shadows)
                        currentMode = PaintMode.AntiErase;
                    else
                        currentMode = PaintMode.Shadows;
                }
            }
            else if (mouseInButton(desaturateButtonPos, buttonHSize))
            {
                if (!desaturateButtonPressed)
                {
                    desaturateButtonPressed = true;
                    if (currentMode == PaintMode.Desaturate)
                        currentMode = PaintMode.AntiErase;
                    else
                        currentMode = PaintMode.Desaturate;
                }
            }
            else if (mouseInButton(undoButtonPos, buttonHSize))
            {
                if (!undoButtonPressed)
                {
                    undoButtonPressed = true;
                    SDL_SetCursor(cursorWait);
                    painter.restore();
                    SDL_SetCursor(cursorArrow);
                }
            }
            else if (mouseInButton(openButtonPos, buttonHSize))
            {
                if (!openButtonPressed)
                {
                    openButtonPressed = true;                    
                    openImageDialog();
                    openButtonPressed = false;
                }
            }
            else if (mouseInButton(saveButtonPos, buttonHSize))
            {
                if (!saveButtonPressed)
                {
                    saveButtonPressed = true;                   
                    saveImageDialog();
                    saveButtonPressed = false;
                }
            }
            else
            {
                if (haveOldPos)
                {
                    Vector2f m = Vector2f(eventManager.mouseX, eventManager.mouseY);
                    painter.paintLine(brush, oldPos, m, currentMode);
                    oldPos = m;
                    painter.updateFrame();
                }
                else
                {
                    painter.backup();
                    Vector2f m = Vector2f(eventManager.mouseX, eventManager.mouseY);
                    painter.paint(brush, m, currentMode);
                    oldPos = m;
                    haveOldPos = true;
                    painter.updateFrame();
                }
            }
        }
        else
        {
            haveOldPos = false;
            eraserButtonPressed = false;
            chromakeyButtonPressed = false;
            erodeButtonPressed = false;
            shadowButtonPressed = false;
            desaturateButtonPressed = false;
            undoButtonPressed = false;
            openButtonPressed = false;
            saveButtonPressed = false;
        }
        
        if (mouseInButton(eraserButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Eraser / Anti-eraser";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(chromakeyButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Apply chroma Key";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(erodeButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Apply alpha channel erosion";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(shadowButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Shadow paint";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(desaturateButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Desaturate paint";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(undoButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Undo (Ctrl+Z)";
            hintPos = Vector2f(6, 72);
        }
        else if (mouseInButton(openButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Open (Ctrl+O)";
            hintPos = Vector2f(eventManager.windowWidth - 128 + 6, 72);
        }
        else if (mouseInButton(saveButtonPos, buttonHSize))
        {
            showHint = true; 
            hint = "Save (Ctrl+S)";
            hintPos = Vector2f(eventManager.windowWidth - 128 + 6, 72);
        }
        else
            showHint = false; 
    }

    override void onRender()
    {
        glViewport(0, 0, eventManager.windowWidth, eventManager.windowHeight);

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glMatrixMode(GL_PROJECTION);
        glLoadMatrixf(projectionMatrix.arrayof.ptr);
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();

        painter.render();

        drawButton(eraserButtonPos, buttonHSize, eraserTexture, currentMode == PaintMode.Erase);
        drawButton(chromakeyButtonPos, buttonHSize, chromakeyTexture, false);
        drawButton(erodeButtonPos, buttonHSize, erodeTexture, false);
        drawButton(shadowButtonPos, buttonHSize, shadowsTexture, currentMode == PaintMode.Shadows);
        drawButton(desaturateButtonPos, buttonHSize, desaturateTexture, currentMode == PaintMode.Desaturate);
        drawButton(undoButtonPos, buttonHSize, undoTexture, false);
        drawButton(openButtonPos, buttonHSize, openTexture, false);
        drawButton(saveButtonPos, buttonHSize, saveTexture, false);

        glPushMatrix();
        glTranslatef(6.0f, eventManager.windowHeight - 20.0f, 0.0f);
        auto c = textImageFilename.color;
        textImageFilename.color = Color4f(0, 0, 0, 1);
        textImageFilename.render();
        textImageFilename.color = c;
        glTranslatef(0, 1, 0);
        textImageFilename.render();
        glPopMatrix();

        if (colorSelectionMode)
        {
            Vector2f m = Vector2f(eventManager.mouseX, eventManager.mouseY);
            Color4f col = painter.getColor(m);
            drawRect(m + Vector2f(32.0f, -32.0f), 16.0f, col, true);
        }
        else if (showHint)
        {
            //Vector2f m = Vector2f(eventManager.mouseX, eventManager.mouseY);
            glPushMatrix();
            glTranslatef(hintPos.x, hintPos.y, 0.0f);
            textHint.text = hint;
            textHint.color = Color4f(0, 0, 0, 1);
            textHint.render();
            textHint.color = Color4f(1, 1, 1, 1);
            glTranslatef(0, 1, 0);
            textHint.render();
            glPopMatrix();
        }
    }

    bool mouseInButton(Vector2f pos, Vector2f hsize)
    {
        return (eventManager.mouseX > (pos.x - hsize.x) && eventManager.mouseX < (pos.x + hsize.x) &&
                eventManager.mouseY > (pos.y - hsize.y) && eventManager.mouseY < (pos.y + hsize.y));
    }

    bool mouseInButton(Vector2f pos, float hsize)
    {
        return (eventManager.mouseX > (pos.x - hsize) && eventManager.mouseX < (pos.x + hsize) &&
                eventManager.mouseY > (pos.y - hsize) && eventManager.mouseY < (pos.y + hsize));
    }

    void drawRect(Vector2f pos, Vector2f hsize, Color4f color, bool drawOutline)
    {
        glPushMatrix();
        glTranslatef(pos.x, pos.y, 0.0f);
        glScalef(hsize.x * 2.0f, hsize.y * 2.0f, 1.0f);
        glColor4fv(color.arrayof.ptr);
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
        if (drawOutline)
        {
            glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
            glBegin(GL_QUADS);
            glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
            glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
            glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
            glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
            glEnd();
            glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
        }
        glPopMatrix();
    }

    void drawRect(Vector2f pos, float hsize, Color4f color, bool drawOutline)
    {
        glPushMatrix();
        glTranslatef(pos.x, pos.y, 0.0f);
        glScalef(hsize * 2.0f, hsize * 2.0f, 1.0f);
        glColor4fv(color.arrayof.ptr);
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
        if (drawOutline)
        {
            glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
            glBegin(GL_QUADS);
            glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
            glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
            glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
            glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
            glEnd();
            glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
        }
        glPopMatrix();
    }

    void drawButton(Vector2f pos, float hsize, Texture tex, bool active)
    {
        glPushMatrix();
        glTranslatef(pos.x, pos.y, 0.0f);
        glScalef(hsize * 2.0f, hsize * 2.0f, 1.0f);
        if (mouseInButton(pos, hsize))
            glColor4f(1.0f, 1.0f, 1.0f, 0.5f);
        else
            glColor4f(0.0f, 0.0f, 0.0f, 0.5f);
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        glColor4f(1.0f, 1.0f, 1.0f, 1.0f);
        if (active)
        {
            glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
            glBegin(GL_QUADS);
            glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
            glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
            glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
            glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
            glEnd();
            glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
        }
        tex.bind();
        glScalef(0.75f, 0.75f, 1.0f);
        glBegin(GL_QUADS);
        glTexCoord2f(0.0f, 1.0f); glVertex2f(-0.5f, -0.5f);
        glTexCoord2f(0.0f, 0.0f); glVertex2f(-0.5f,  0.5f);
        glTexCoord2f(1.0f, 0.0f); glVertex2f( 0.5f,  0.5f);
        glTexCoord2f(1.0f, 1.0f); glVertex2f( 0.5f, -0.5f);
        glEnd();
        tex.unbind();
        glPopMatrix();
    }
}

void main(string[] args)
{
    //writeln("Allocated memory at start: ", allocatedMemory);
    string title = format("ChromaKeyer %s.%s.%s", CKVersionMajor, CKVersionMinor, CKVersionPatch);
    
    Properties settings = New!Properties(null);
    if (exists("settings.conf"))
    {
        parseProperties(readText("settings.conf"), settings);
        
        if ("NumUndoLevels" in settings)
            NumUndoLevels = settings["NumUndoLevels"].toUInt;
            
        if ("ChromaKeyMinDistance" in settings)
            ChromaKeyMinDistance = settings["ChromaKeyMinDistance"].toFloat;
            
        if ("ChromaKeyMaxDistance" in settings)
            ChromaKeyMaxDistance = settings["ChromaKeyMaxDistance"].toFloat;
    }
    
    SMApplication app = New!SMApplication(1024, 768, title, args, settings);
    app.run();
    Delete(app);
    Delete(settings);
    //writeln("Allocated memory at end: ", allocatedMemory);
}
