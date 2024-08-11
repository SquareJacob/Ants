#include <SDL.h>
#include <SDL_image.h>
#include <SDL_ttf.h>
#include <SDL_mixer.h>
#include <iostream>
#include <stdlib.h>  
#include <crtdbg.h>   //for malloc and free
#include <set>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#define _CRTDBG_MAP_ALLOC
#ifdef _DEBUG
#define new new( _NORMAL_BLOCK, __FILE__, __LINE__)
#endif

SDL_Window* window;
SDL_Renderer* renderer;
bool running;
SDL_Event event;
std::set<std::string> keys;
std::set<std::string> currentKeys;
int mouseX = 0;
int mouseY = 0;
int mouseDeltaX = 0;
int mouseDeltaY = 0;
int mouseScroll = 0;
std::set<int> buttons;
std::set<int> currentButtons;
const int WIDTH = 800;
const int HEIGHT = 600;

void debug(int line, std::string file) {
	std::cout << "Line " << line << " in file " << file << ": " << SDL_GetError() << std::endl;
}

double random() {
	return static_cast<double>(rand()) / static_cast<double>(RAND_MAX);
}

double mod(double m, double n) {
	double result = m;
	if (result < 0) {
		while (result < 0) {
			result += n;
		}
	}
	else {
		while (result > n) {
			result -= n;
		}
	}
	return result;
}

const int BRUSHSIZE = 30;
const int MAXFOODPERPIXEL = 5;
int food[HEIGHT * WIDTH] = { 0 };

//strength, angle
struct Pheremone {
	double strength = 0.0;
	double angle = 0.0;
};
Pheremone foodPheremones[HEIGHT * WIDTH];
Pheremone homePheremones[HEIGHT * WIDTH];

double speed = 1.0;
double trailDecay = 0.01;
double strengthDecay = 0.001;
double sensorDistance = 0.0;
double sensorAngle = M_PI / 4;
double rotateAmount = M_PI / 6;
double randomRotate = M_PI / 12;
const Uint32 red = 0x01000000, green = 0x00010000, blue = 0x00000100;
class Ant {
public:
	uint8_t r = 0, g = 0, b = 0;
	bool hasFood = false;
	double x = 0.0, y = 0.0, angle = 0.0, colonyX = 0.0, colonyY = 0.0, colonyRadius = 0.0, strength = 1.0;
	void draw(Uint32* pixel_ptr) {
		pixel_ptr[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = red * r + green * g + blue * b + 255;
	}
	bool move() {
		angle += (2.0 * random() - 1.0) * randomRotate;
		double deltaX = speed * cos(angle);
		double deltaY = speed * sin(angle);
		if (0.0 < x + deltaX && x + deltaX < WIDTH && 0.0 < y + deltaY && y + deltaY < HEIGHT) {
			x += deltaX;
			y += deltaY;
			if (strength > 0.0) {
				strength -= strengthDecay;
				if (strength < 0.0) {
					strength = 0.0;
				}
			}
			return true;
		}
		else {
			angle = random() * 2.0 * M_PI;
			strength = 0.0;
			return false;
		}
	}
	void trail() {
		if (hasFood) {
			if (foodPheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)].strength < strength) {
				foodPheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = { strength, angle };
			}
		}
		else {
			if (homePheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)].strength < strength) {
				homePheremones[static_cast<int>(y) * WIDTH + static_cast<int>(x)] = { strength, angle };
			}
			if (food[static_cast<int>(y) * WIDTH + static_cast<int>(x)] > 0) {
				food[static_cast<int>(y) * WIDTH + static_cast<int>(x)]--;
				hasFood = true;
				r = 255;
				b = 0;
				angle -= M_PI;
				strength = 1.0;
			}
		}
		if ((x - colonyX) * (x - colonyX) + (y - colonyY) * (y - colonyY) < colonyRadius * colonyRadius) {
			hasFood = false;
			r = 0;
			b = 255;
			angle += M_PI;
			strength = 1.0;
		}
	}
	void sense() {
		Pheremone frontSensor;
		Pheremone leftSensor;
		Pheremone rightSensor;
		if (hasFood) {
			frontSensor = homePheremones[static_cast<int>(y + sensorDistance * sin(angle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle))];
			leftSensor = homePheremones[static_cast<int>(y + sensorDistance * sin(angle + sensorAngle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle + sensorAngle))];
			rightSensor = homePheremones[static_cast<int>(y + sensorDistance * sin(angle - sensorAngle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle - sensorAngle))];
		}
		else {
			frontSensor = foodPheremones[static_cast<int>(y + sensorDistance * sin(angle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle))];
			leftSensor = foodPheremones[static_cast<int>(y + sensorDistance * sin(angle + sensorAngle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle + sensorAngle))];
			rightSensor = foodPheremones[static_cast<int>(y + sensorDistance * sin(angle - sensorAngle)) * WIDTH + static_cast<int>(x + sensorDistance * cos(angle - sensorAngle))];
		}
		double maxStrength = std::max(frontSensor.strength, std::max(leftSensor.strength, rightSensor.strength));
		if (maxStrength > 0.0) {
			double newAngle;
			if (frontSensor.strength == maxStrength) {
				newAngle = frontSensor.angle;
			}
			else if (leftSensor.strength == maxStrength) {
				newAngle = leftSensor.angle;
			}
			else if (rightSensor.strength == maxStrength) {
				newAngle = rightSensor.angle;
			}
			//angle = newAngle + M_PI;
			angle = mod(angle, 2.0 * M_PI);
			newAngle = mod(newAngle + M_PI, 2.0 * M_PI);
			if (abs(angle - newAngle) < rotateAmount) {
				angle = newAngle;
			}
			else if (newAngle < angle) {
				if (angle - newAngle < M_PI) {
					angle -= rotateAmount;
				}
				else {
					angle += rotateAmount;
				}
			}
			else {
				if (newAngle - angle < M_PI) {
					angle += rotateAmount;
				}
				else {
					angle -= rotateAmount;
				}
			}
		}
	}
};

const int ANTS = 25000;
class Colony {
public:
	uint8_t r = 0, g = 0, b = 255;
	int radius = 15.0, x = WIDTH / 2, y = HEIGHT / 2;
	Ant ants[ANTS];
	void draw(Uint32* pixel_ptr) {
		for (int i = -radius; i <= radius; i++) {
			for (int j = -radius; j <= radius; j++) {
				if (i * i + j * j < radius * radius) {
					pixel_ptr[(y + j) * WIDTH + (x + i)] = red * r + green * g + blue * b + 255;
				}
			}
		}
	}
	void setup() {
		Ant* a;
		double angle;
		for (int i = 0; i < ANTS; i++) {
			a = &ants[i];
			a->r = r;
			a->g = g;
			a->b = b;
			angle = random() * 2.0 * M_PI;
			a->x = x + radius * cos(angle);
			a->y = y + radius * sin(angle);
			a->colonyX = x;
			a->colonyY = y;
			a->colonyRadius = radius;
			a->angle = angle;
		}
	}
};
Colony colony;

int main(int argc, char* argv[]) {
	if (SDL_Init(SDL_INIT_EVERYTHING) == 0 && TTF_Init() == 0 && Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 2048) == 0) {
		//Setup
		window = SDL_CreateWindow("Window", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIDTH, HEIGHT, 0);
		if (window == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}

		renderer = SDL_CreateRenderer(window, -1, 0);
		if (renderer == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}
		srand(time(0));
		colony.setup();

		SDL_Texture* texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA8888,
			SDL_TEXTUREACCESS_STREAMING, WIDTH, HEIGHT);
		void* txtPixels;
		int pitch;
		SDL_PixelFormat* format = SDL_AllocFormat(SDL_PIXELFORMAT_RGBA8888);
		Uint32* pixel_ptr;

		//Main loop
		running = true;
		while (running) {
			//handle events
			for (std::string i : keys) {
				currentKeys.erase(i); //make sure only newly pressed keys are in currentKeys
			}
			for (int i : buttons) {
				currentButtons.erase(i); //make sure only newly pressed buttons are in currentButtons
			}
			mouseScroll = 0;
			while (SDL_PollEvent(&event)) {
				switch (event.type) {
				case SDL_QUIT:
					running = false;
					break;
				case SDL_KEYDOWN:
					if (!keys.contains(std::string(SDL_GetKeyName(event.key.keysym.sym)))) {
						currentKeys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym)));
					}
					keys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym))); //add keydown to keys set
					break;
				case SDL_KEYUP:
					keys.erase(std::string(SDL_GetKeyName(event.key.keysym.sym))); //remove keyup from keys set
					break;
				case SDL_MOUSEMOTION:
					mouseX = event.motion.x;
					mouseY = event.motion.y;
					mouseDeltaX = event.motion.xrel;
					mouseDeltaY = event.motion.yrel;
					break;
				case SDL_MOUSEBUTTONDOWN:
					if (!buttons.contains(event.button.button)) {
						currentButtons.insert(event.button.button);
					}
					buttons.insert(event.button.button);
					break;
				case SDL_MOUSEBUTTONUP:
					buttons.erase(event.button.button);
					break;
				case SDL_MOUSEWHEEL:
					mouseScroll = event.wheel.y;
					break;
				}
			}

			if (currentButtons.contains(1) || buttons.contains(3)) {
				for (int i = -BRUSHSIZE; i <= BRUSHSIZE; i++) {
					for (int j = -BRUSHSIZE; j <= BRUSHSIZE; j++) {
						if (i * i + j * j < BRUSHSIZE * BRUSHSIZE) {
							if (food[(mouseY + j) * WIDTH + (mouseX + i)] < MAXFOODPERPIXEL) {
								food[(mouseY + j) * WIDTH + (mouseX + i)]++;
							}
						}
					}
				}
			}

			for (int i = 0; i < WIDTH * HEIGHT; i++) {
				if (foodPheremones[i].strength > 0.0) {
					foodPheremones[i].strength -= trailDecay;
					if (foodPheremones[i].strength < 0.0) {
						foodPheremones[i].strength = 0.0;
					}
				}
				if (homePheremones[i].strength > 0.0) {
					homePheremones[i].strength -= trailDecay;
					if (homePheremones[i].strength < 0.0) {
						homePheremones[i].strength = 0.0;
					}
				}
			}

			Ant* a;
			for (int i = 0; i < ANTS; i++) {
				a = &colony.ants[i];
				if (a->move()) {
					a->trail();
				}
			}

			SDL_LockTexture(texture, NULL, &txtPixels, &pitch);
			pixel_ptr = (Uint32*)txtPixels;
			for (int i = 0; i < WIDTH * HEIGHT; i++) {
				pixel_ptr[i] = (food[i] * 255 / MAXFOODPERPIXEL) * green + 255;
			}
			for (int i = 0; i < ANTS; i++) {
				a = &colony.ants[i];
				a->sense();
				a->draw(pixel_ptr);
			}
			colony.draw(pixel_ptr);
			SDL_UnlockTexture(texture);
			SDL_RenderCopy(renderer, texture, NULL, NULL);
			SDL_RenderPresent(renderer);
		}

		//Clean up
		if (window) {
			SDL_DestroyWindow(window);
		}
		if (renderer) {
			SDL_DestroyRenderer(renderer);
		}
		TTF_Quit();
		Mix_Quit();
		IMG_Quit();
		SDL_Quit();
		return 0;
	}
	else {
		return 0;
	}
}